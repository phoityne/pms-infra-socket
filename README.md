# pms-infra-socket

`pms-infra-socket` is a library within the [`pty-mcp-server`](https://github.com/phoityne/pty-mcp-server) project.  
It provides an abstraction layer for interacting with socket-based communication endpoints in a structured and asynchronous way.  
This enables AI agents to send and receive byte streams, manage connection lifecycles, and log protocol-specific exchanges with fine-grained control.  

The module is designed for composability and observability, supporting scenarios such as Telnet negotiation, binary protocol exchanges, and real-time I/O monitoring over TCP/IP sockets.

---

## Package Structure
![Package Structure](https://raw.githubusercontent.com/phoityne/pms-infra-socket/main/docs/01_package_structure.png)
---

## Module Structure
![Module Structure](https://raw.githubusercontent.com/phoityne/pms-infra-socket/main/docs/02_module_structure.png)

---
