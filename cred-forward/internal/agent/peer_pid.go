package agent

import (
	"fmt"
	"net"
	"syscall"
)

func peerPID(conn net.Conn) (int, error) {
	syscallConn, ok := conn.(syscall.Conn)
	if !ok {
		return 0, fmt.Errorf("connection type %T does not expose peer credentials", conn)
	}
	rawConn, err := syscallConn.SyscallConn()
	if err != nil {
		return 0, err
	}
	var pid int
	var socketErr error
	if err := rawConn.Control(func(fd uintptr) {
		pid, socketErr = peerPIDFromFD(int(fd))
	}); err != nil {
		return 0, err
	}
	if socketErr != nil {
		return 0, socketErr
	}
	return pid, nil
}
