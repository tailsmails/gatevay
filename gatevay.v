import net
import os
import time

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

fn copy_data(mut src net.TcpConn, mut dst net.TcpConn) {
	mut buf := []u8{len: 8192}
	for {
		n := src.read(mut buf) or { break }
		if n == 0 { break }
		dst.write(buf[..n]) or { break }
	}
	src.close() or {}
	dst.close() or {}
}

fn dial_with_bind_safe(host string, port u16, bind_ip string) !&net.TcpConn {
	is_ipv6_bind := bind_ip.contains(':')
	family := if is_ipv6_bind { net.AddrFamily.ip6 } else { net.AddrFamily.ip }

	local_bind := format_bind_addr(bind_ip, 0)
	dest := format_dest_addr(host, port)

	addrs := net.resolve_addrs(dest, family, .tcp) or {
		return error('could not resolve ${dest} for family ${family}: ${err}')
	}

	if addrs.len == 0 {
		return error('no addresses resolved for ${dest}')
	}

	mut err_msg := ''
	for addr in addrs {
		resolved_dest := addr.str()
		mut target := net.dial_tcp_with_bind(resolved_dest, local_bind) or {
			err_msg = err.msg()
			continue
		}
		return target
	}
	return error('dial_with_bind_safe failed for address ${dest}: ${err_msg}')
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

		spawn copy_data(mut client, mut target)
		copy_data(mut target, mut client)
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
