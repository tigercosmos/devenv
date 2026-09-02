package agent

import "syscall"

const (
	solLocal     = 0
	localPeerPID = 0x002
)

func peerPIDFromFD(fd int) (int, error) {
	return syscall.GetsockoptInt(fd, solLocal, localPeerPID)
}
