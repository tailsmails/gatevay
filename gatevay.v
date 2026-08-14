import net
import os
import time

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

struct C.in_addr {
mut:
	s_addr u32
}

struct C.sockaddr_in {
mut:
	sin_family u16
	sin_port   u16
	sin_addr   C.in_addr
	sin_zero   [8]u8
}

fn C.socket(domain int, s_type int, protocol int) int
// fn C.setsockopt(sockfd int, level int, optname int, optval voidptr, optlen int) int
// fn C.bind(sockfd int, addr voidptr, addrlen int) int
// fn C.connect(sockfd int, addr voidptr, addrlen int) int
fn C.close(sockfd int) int
fn C.inet_pton(af int, src &char, dst voidptr) int
fn C.strerror(errnum int) &char
fn C.recv(sockfd int, buf voidptr, len int, flags int) int
fn C.send(sockfd int, buf voidptr, len int, flags int) int

struct Target {
	bind_ip    string
	local_port int
}

struct ClientUdpState {
mut:
	has_addr bool
	addr     net.Addr
}

fn bytes_to_ipv6(b []u8) string {
	mut parts := []string{len: 8}
	for i in 0 .. 8 {
		val := (u16(b[i * 2]) << 8) | b[i * 2 + 1]
		parts[i] = '${val:x}'
	}
	return parts.join(':')
}

fn format_bind_addr(ip string, port int) string {
	if ip.contains(':') {
		return '[${ip}]:${port}'
	}
	return '${ip}:${port}'
}

fn format_dest_addr(host string, port u16) string {
	if host.contains(':') && !host.starts_with('[') {
		return '[${host}]:${port}'
	}
	return '${host}:${port}'
}

fn parse_addr_str(s string) (string, u16) {
	if s.contains('[') {
		parts := s.split(']')
		ip := parts[0].trim('[')
		port_str := parts[1].trim(':')
		return ip, u16(port_str.int())
	} else if s.count(':') > 1 {
		return s, 0
	} else {
		parts := s.split(':')
		if parts.len == 2 {
			return parts[0], u16(parts[1].int())
		}
		return s, 0
	}
}

fn read_exact(mut conn net.TcpConn, mut buf []u8) ! {
	mut total := 0
	for total < buf.len {
		n := conn.read(mut buf[total..])!
		if n == 0 {
			return error('unexpected connection close')
		}
		total += n
	}
}

fn copy_data_thread(src_fd int, dst_fd int, name string, ch chan bool) {
	mut buf := []u8{len: 8192}
	for {
		n := C.recv(src_fd, buf.data, 8192, 0)
		if n < 0 {
			err_code := C.errno
			err_str := unsafe { C.strerror(err_code).vstring() }
			println('Copy [${name}] -> Read failed (errno ${err_code}: ${err_str})')
			break
		}
		if n == 0 {
			println('Copy [${name}] -> EOF reached')
			break
		}
		mut total := 0
		mut failed := false
		for total < n {
			sent := C.send(dst_fd, voidptr(u64(buf.data) + u64(total)), n - total, 0)
			if sent < 0 {
				err_code := C.errno
				err_str := unsafe { C.strerror(err_code).vstring() }
				println('Copy [${name}] -> Write failed (errno ${err_code}: ${err_str})')
				failed = true
				break
			}
			total += sent
		}
		if failed {
			break
		}
		println('Copy [${name}] -> Transmitted ${n} bytes')
	}
	C.close(src_fd)
	C.close(dst_fd)
	println('Copy [${name}] -> Closed')
	ch <- true
}

fn my_htons(n u16) u16 {
	return ((n & 0xff) << 8) | ((n & 0xff00) >> 8)
}

fn get_interface_name(ip string) string {
	res := os.execute('ip -o addr show')
	if res.exit_code != 0 {
		if ip.starts_with('192.168.') {
			return 'wlan0'
		}
		return 'ccmni0'
	}
	for line in res.output.split_into_lines() {
		if line.contains(' ${ip}/') || line.contains(' ${ip} ') {
			parts := line.split(' ')
			mut clean_parts := []string{}
			for p in parts {
				trimmed := p.trim_space()
				if trimmed != '' {
					clean_parts << trimmed
				}
			}
			if clean_parts.len >= 2 {
				return clean_parts[1].trim_space()
			}
		}
	}
	if ip.starts_with('192.168.') {
		return 'wlan0'
	}
	return 'ccmni0'
}

fn get_default_interface() string {
	res := os.execute('ip route show')
	if res.exit_code != 0 {
		return 'wlan0'
	}
	for line in res.output.split_into_lines() {
		if line.starts_with('default ') {
			parts := line.split(' ')
			for i, part in parts {
				if part == 'dev' && i + 1 < parts.len {
					return parts[i+1].trim_space()
				}
			}
		}
	}
	return 'wlan0'
}

fn find_native_table(ifname string) string {
	mut res := os.execute('ip route show table all')
	if res.exit_code != 0 {
		res = os.execute('ip route show table 0')
		if res.exit_code != 0 {
			return ''
		}
	}
	for line in res.output.split_into_lines() {
		if line.contains('dev ${ifname}') {
			parts := line.split(' ')
			for i, part in parts {
				if part == 'table' && i + 1 < parts.len {
					return parts[i+1].trim_space()
				}
			}
		}
	}
	return ''
}

fn setup_routing(ip string) {
	ifname := get_interface_name(ip)
	default_ifname := get_default_interface()

	if ifname == default_ifname {
		table_id := if ifname == 'wlan0' { 101 } else { 100 }
		os.execute('ip rule del from ${ip} table ${table_id} 2>/dev/null')
		os.execute('ip route flush table ${table_id} 2>/dev/null')
		println('Using default system routing for primary interface [${ifname}]: [${ip}]')
		return
	}

	mut table_id := find_native_table(ifname)
	if table_id == '' {
		table_id = '100'
		os.execute('ip route flush table 100 2>/dev/null')
		os.execute('ip route add default dev ${ifname} table 100')
	}

	priority := 50

	os.execute('ip rule del from ${ip} table ${table_id} 2>/dev/null')
	os.execute('ip rule del from ${ip} priority ${priority} 2>/dev/null')

	os.execute('ip rule add from ${ip} table ${table_id} priority ${priority}')

	println('Routing auto-configured for secondary interface: [${ip}] -> dev [${ifname}] (table ${table_id})')
}

fn dial_with_bind_safe(host string, port u16, bind_ip string) !&net.TcpConn {
	dest := format_dest_addr(host, port)
	println('Proxy [${bind_ip}] -> Resolving address for: ${dest}')
	addrs := net.resolve_addrs(dest, .ip, .tcp) or {
		return error('could not resolve ${dest}: ${err}')
	}
	if addrs.len == 0 {
		return error('no addresses resolved for ${dest}')
	}

	remote_ip_str, remote_port := parse_addr_str(addrs[0].str())
	println('Proxy [${bind_ip}] -> Resolved ${dest} to ${remote_ip_str}:${remote_port}')

	sockfd := C.socket(2, 1, 0)
	if sockfd < 0 {
		err_code := C.errno
		err_str := unsafe { C.strerror(err_code).vstring() }
		return error('socket creation failed (errno ${err_code}: ${err_str})')
	}

	optval := 1
	if C.setsockopt(sockfd, 1, 2, &optval, sizeof(int)) < 0 {
		err_code := C.errno
		err_str := unsafe { C.strerror(err_code).vstring() }
		C.close(sockfd)
		return error('setsockopt SO_REUSEADDR failed (errno ${err_code}: ${err_str})')
	}

	mut local_addr := C.sockaddr_in{}
	local_addr.sin_family = 2
	local_addr.sin_port = my_htons(0)
	if C.inet_pton(2, bind_ip.str, &local_addr.sin_addr) <= 0 {
		C.close(sockfd)
		return error('invalid local bind IP: ${bind_ip}')
	}

	println('Proxy [${bind_ip}] -> Binding socket to local IP...')
	if C.bind(sockfd, voidptr(&local_addr), sizeof(C.sockaddr_in)) < 0 {
		err_code := C.errno
		err_str := unsafe { C.strerror(err_code).vstring() }
		C.close(sockfd)
		return error('bind failed to ${bind_ip} (errno ${err_code}: ${err_str})')
	}

	mut remote_addr := C.sockaddr_in{}
	remote_addr.sin_family = 2
	remote_addr.sin_port = my_htons(remote_port)
	if C.inet_pton(2, remote_ip_str.str, &remote_addr.sin_addr) <= 0 {
		C.close(sockfd)
		return error('invalid remote IP: ${remote_ip_str}')
	}

	println('Proxy [${bind_ip}] -> Connecting to ${remote_ip_str}:${remote_port}...')
	if C.connect(sockfd, voidptr(&remote_addr), sizeof(C.sockaddr_in)) < 0 {
		err_code := C.errno
		err_str := unsafe { C.strerror(err_code).vstring() }
		C.close(sockfd)
		return error('connect failed to ${remote_ip_str}:${remote_port} from ${bind_ip} (errno ${err_code}: ${err_str})')
	}

	println('Proxy [${bind_ip}] -> Connected successfully to ${dest}!')
	sock := net.TcpSocket{
		handle: sockfd
	}
	return &net.TcpConn{
		sock: sock
		handle: sockfd
		is_blocking: true
	}
}

fn handle_udp_associate(mut client net.TcpConn, bind_ip string) ! {
	mut udp_listener := net.listen_udp('127.0.0.1:0')!
	defer { udp_listener.close() or {} }

	local_bind := format_bind_addr(bind_ip, 0)
	mut udp_sender := net.listen_udp(local_bind)!
	defer { udp_sender.close() or {} }

	local_addr := net.addr_from_socket_handle(udp_listener.sock.handle)
	udp_port := local_addr.port() or { 0 }

	mut reply := [u8(5), 0, 0, 1]
	reply << 127
	reply << 0
	reply << 0
	reply << 1
	reply << u8(udp_port >> 8)
	reply << u8(udp_port & 0xFF)
	client.write(reply)!

	shared state := ClientUdpState{
		has_addr: false
		addr: net.Addr{}
	}

	spawn fn (mut listener net.UdpConn, mut sender net.UdpConn, shared state ClientUdpState) {
		for {
			mut buf := []u8{len: 2048}
			n, from_addr := sender.read(mut buf) or { break }
			
			mut client_addr := net.Addr{}
			mut ok := false
			rlock state {
				ok = state.has_addr
				client_addr = state.addr
			}
			if !ok {
				continue
			}

			ip, port := parse_addr_str(from_addr.str())
			
			mut resp := []u8{}
			resp << 0
			resp << 0
			resp << 0
			resp << 3
			resp << u8(ip.len)
			for c in ip {
				resp << u8(c)
			}
			resp << u8(port >> 8)
			resp << u8(port & 0xFF)
			resp << buf[..n]

			listener.write_to(client_addr, resp) or {}
		}
	}(mut udp_listener, mut udp_sender, shared state)

	is_ipv6_bind := bind_ip.contains(':')
	family := if is_ipv6_bind { net.AddrFamily.ip6 } else { net.AddrFamily.ip }

	for {
		mut buf := []u8{len: 2048}
		n, client_addr := udp_listener.read(mut buf) or { break }
		if n < 10 { continue }
		
		lock state {
			if !state.has_addr {
				state.addr = client_addr
				state.has_addr = true
			}
		}

		if buf[0] != 0 || buf[1] != 0 || buf[2] != 0 {
			continue
		}

		atyp := buf[3]
		mut target_host := ''
		mut target_port := u16(0)
		mut data_start := 0

		if atyp == 1 {
			target_host = '${buf[4]}.${buf[5]}.${buf[6]}.${buf[7]}'
			target_port = (u16(buf[8]) << 8) | buf[9]
			data_start = 10
		} else if atyp == 3 {
			domain_len := int(buf[4])
			target_host = buf[5 .. 5 + domain_len].bytestr()
			target_port = (u16(buf[5 + domain_len]) << 8) | buf[5 + domain_len + 1]
			data_start = 5 + domain_len + 2
		} else if atyp == 4 {
			if n < 22 { continue }
			target_host = bytes_to_ipv6(buf[4 .. 20])
			target_port = (u16(buf[20]) << 8) | buf[21]
			data_start = 22
		} else {
			continue
		}

		target_addr := '${target_host}:${target_port}'
		addrs := net.resolve_addrs(target_addr, family, .udp) or { continue }
		if addrs.len == 0 { continue }
		
		udp_sender.write_to(addrs[0], buf[data_start .. n]) or {}
	}
}

fn handle_socks5(mut client net.TcpConn, bind_ip string) ! {
	defer {
		client.close() or {}
	}

	mut hello := []u8{len: 2}
	read_exact(mut client, mut hello)!
	if hello[0] != 5 {
		return error('invalid protocol version')
	}
	num_methods := int(hello[1])
	mut methods := []u8{len: num_methods}
	read_exact(mut client, mut methods)!

	client.write([u8(5), 0])!

	mut req_header := []u8{len: 4}
	read_exact(mut client, mut req_header)!
	cmd := req_header[1]
	atyp := req_header[3]

	mut host := ''
	mut port := u16(0)

	if atyp == 1 {
		mut addr_buf := []u8{len: 6}
		read_exact(mut client, mut addr_buf)!
		host = '${addr_buf[0]}.${addr_buf[1]}.${addr_buf[2]}.${addr_buf[3]}'
		port = (u16(addr_buf[4]) << 8) | addr_buf[5]
	} else if atyp == 3 {
		mut len_buf := []u8{len: 1}
		read_exact(mut client, mut len_buf)!
		domain_len := int(len_buf[0])
		mut addr_buf := []u8{len: domain_len + 2}
		read_exact(mut client, mut addr_buf)!
		host = addr_buf[0 .. domain_len].bytestr()
		port = (u16(addr_buf[domain_len]) << 8) | addr_buf[domain_len + 1]
	} else if atyp == 4 {
		mut addr_buf := []u8{len: 18}
		read_exact(mut client, mut addr_buf)!
		host = bytes_to_ipv6(addr_buf[0 .. 16])
		port = (u16(addr_buf[16]) << 8) | addr_buf[17]
	} else {
		return error('unsupported address type')
	}

	if cmd == 1 {
		mut target := dial_with_bind_safe(host, port, bind_ip) or {
			client.write([u8(5), 1, 0, 1, 0, 0, 0, 0, 0, 0]) or {}
			return err
		}
		
		client.write([u8(5), 0, 0, 1, 0, 0, 0, 0, 0, 0])!

		ch := chan bool{}
		spawn copy_data_thread(client.sock.handle, target.sock.handle, 'ClientToTarget', ch)
		spawn copy_data_thread(target.sock.handle, client.sock.handle, 'TargetToClient', ch)
		_ = <-ch
	} else if cmd == 3 {
		handle_udp_associate(mut client, bind_ip)!
	} else {
		client.write([u8(5), 7, 0, 1, 0, 0, 0, 0, 0, 0]) or {}
		return error('unsupported command')
	}
}

fn handle_socks5_wrapper(mut client net.TcpConn, bind_ip string) {
	handle_socks5(mut client, bind_ip) or { eprintln('Error: ${err}') }
}

fn start_gateway(port int, ip string) {
	mut listener := net.listen_tcp(.ip, '0.0.0.0:${port}') or {
		eprintln('Failed to listen on port ${port}: ${err}')
		return
	}
	println('Gateway active on port ${port} -> outbound bound to [${ip}]')
	for {
		mut client := listener.accept() or { continue }
		spawn handle_socks5_wrapper(mut client, ip)
	}
}

fn main() {
	if os.args.len < 2 {
		print_usage()
		return
	}

	joined_args := os.args[1..].join(',')
	parts := joined_args.split(',')
	
	mut clean_parts := []string{}
	for p in parts {
		trimmed := p.trim_space()
		if trimmed != '' {
			clean_parts << trimmed
		}
	}

	if clean_parts.len == 0 {
		print_usage()
		return
	}

	if clean_parts.len % 2 != 0 {
		eprintln('Error: Arguments must be in pairs of <gateway_ip>,<local_port>')
		print_usage()
		return
	}

	mut targets := []Target{}
	for i := 0; i < clean_parts.len; i += 2 {
		bind_ip := clean_parts[i]
		local_port := clean_parts[i + 1].int()
		if local_port <= 0 || local_port > 65535 {
			eprintln('Error: Invalid port number "${clean_parts[i + 1]}"')
			return
		}
		targets << Target{
			bind_ip: bind_ip
			local_port: local_port
		}
	}

	println('Starting SOCKS5 Multi-Gateway Proxy Tool...')
	for target in targets {
		setup_routing(target.bind_ip)
		spawn start_gateway(target.local_port, target.bind_ip)
	}

	for {
		time.sleep(10 * time.second)
	}
}

fn print_usage() {
	println('Usage:')
	println('  ${os.args[0]} <gateway_ip1>,<local_port1>,<gateway_ip2>,<local_port2>,...')
	println('Examples:')
	println('  ${os.args[0]} 192.168.1.1,8080,123.45.67.89,9999')
	println('  ${os.args[0]} 192.168.1.1 8080 123.45.67.89 9999')
}
