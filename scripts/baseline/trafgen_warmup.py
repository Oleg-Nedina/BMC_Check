#!/usr/bin/env python3
import socket
import sys
import struct
import time

def main():
    if len(sys.argv) < 2:
        print("Usage: {} <server_ip>".format(sys.argv[0]))
        sys.exit(1)

    server_ip = sys.argv[1]
    server_port = 11211

    # Memcached UDP Header (8 bytes)
    # Request ID: 1, Sequence: 0, Total Datagrams: 1, Reserved: 0
    udp_hdr = struct.pack(">HHHH", 1, 0, 1, 0)

    # 1. Warm-up: send a SET request for key "key_test_0000000" (16 bytes)
    key = "key_test_0000000"
    val = "1234567890123456789012345678901234567890123456789012345678901234" # 64 bytes
    set_cmd = "set {} 0 0 64\r\n{}\r\n".format(key, val).encode('ascii')
    
    set_pkt = udp_hdr + set_cmd

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(2.0)

    try:
        print("Sending SET request to {}:{}...".format(server_ip, server_port))
        sock.sendto(set_pkt, (server_ip, server_port))
        
        # Expect response "STORED\r\n"
        data, addr = sock.recvfrom(2048)
        # Skip UDP header (8 bytes)
        resp = data[8:].decode('ascii')
        print("Response received (length {}): {}".format(len(data), repr(resp)))
        if "STORED" not in resp:
            print("ERROR: SET failed!")
            sys.exit(1)
        print("SET successful. Cache populated.")

        # Give the server a small moment to let TC egress save the entry
        time.sleep(0.5)

        # 2. Sanity Check: send a GET request for key
        get_cmd = "get {}\r\n".format(key).encode('ascii')
        get_pkt = udp_hdr + get_cmd
        print("Sending GET request sanity check...")
        sock.sendto(get_pkt, (server_ip, server_port))

        data, addr = sock.recvfrom(2048)
        resp = data[8:].decode('ascii')
        print("Response received: {}".format(repr(resp)))
        if val not in resp:
            print("ERROR: GET response did not match populated value!")
            sys.exit(1)
        print("GET sanity check successful!")
        
    except Exception as e:
        print("Socket operation failed: {}".format(e))
        sys.exit(1)
    finally:
        sock.close()

if __name__ == "__main__":
    main()
