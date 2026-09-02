// Package agent serves credentials over a user-only Unix-domain socket.
package agent

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"syscall"
	"time"

	"github.com/tigercosmos/devenv/cred-forward/internal/protocol"
	"github.com/tigercosmos/devenv/cred-forward/internal/provider"
)

var (
	socketUmaskMu sync.Mutex
	socketLockMu  sync.Mutex
	socketLocks   = make(map[string]struct{})
)

// Server serves a provider Registry.
type Server struct {
	Providers provider.Registry
	Timeout   time.Duration
	AuditLog  *log.Logger
}

// NewAuditLogger creates the logger used for credential request records.
func NewAuditLogger(writer io.Writer) *log.Logger {
	return log.New(writer, "cred-agent: request ", 0)
}

// Serve accepts connections until the listener closes or the context ends.
func (s Server) Serve(ctx context.Context, listener net.Listener) error {
	var connections sync.WaitGroup
	defer connections.Wait()
	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-ctx.Done():
			_ = listener.Close()
		case <-done:
		}
	}()
	var retryDelay time.Duration
	for {
		conn, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return nil
			}
			if retryableAcceptError(err) {
				if retryDelay == 0 {
					retryDelay = 5 * time.Millisecond
				} else {
					retryDelay *= 2
					if retryDelay > time.Second {
						retryDelay = time.Second
					}
				}
				timer := time.NewTimer(retryDelay)
				select {
				case <-ctx.Done():
					timer.Stop()
					return nil
				case <-timer.C:
					continue
				}
			}
			return err
		}
		retryDelay = 0
		connections.Add(1)
		go func() {
			defer connections.Done()
			s.handle(ctx, conn)
		}()
	}
}

func retryableAcceptError(err error) bool {
	var netErr net.Error
	return errors.As(err, &netErr) && netErr.Temporary()
}

func (s Server) handle(ctx context.Context, conn net.Conn) {
	defer conn.Close()
	peer := "unknown"
	if pid, err := peerPID(conn); err == nil {
		peer = strconv.Itoa(pid)
	}
	service := "-"
	status := "invalid-request"
	defer func() { s.logRequest(service, status, peer) }()
	timeout := s.Timeout
	if timeout == 0 {
		timeout = 15 * time.Second
	}
	_ = conn.SetDeadline(time.Now().Add(timeout))
	reader := bufio.NewReaderSize(conn, protocol.MaxHeaderSize)
	requestedService, err := protocol.ReadRequest(reader)
	if err != nil {
		_ = protocol.WriteError(conn, "invalid-request")
		return
	}
	service = requestedService
	if !protocol.ValidService(service) {
		status = "unknown-service"
		_ = protocol.WriteError(conn, "unknown-service")
		return
	}
	credential, err := s.Providers.Credential(ctx, service)
	if err != nil {
		status = "unavailable"
		_ = protocol.WriteError(conn, "unavailable")
		return
	}
	if err := protocol.WriteCredential(conn, credential); err != nil {
		status = "internal"
		_ = protocol.WriteError(conn, "internal")
		return
	}
	status = "ok"
}

func (s Server) logRequest(service, status, peer string) {
	if s.AuditLog == nil {
		return
	}
	s.AuditLog.Printf(
		"timestamp=%s service=%s status=%s peer_pid=%s",
		time.Now().UTC().Format(time.RFC3339), service, status, peer,
	)
}

// Listen creates a Unix socket with mode 0600 and returns a race-safe cleanup function.
func Listen(path string) (net.Listener, func() error, error) {
	if !filepath.IsAbs(path) {
		return nil, nil, errors.New("socket path must be absolute")
	}
	if len(path) > maxUnixSocketPath {
		return nil, nil, fmt.Errorf("socket path is too long: use a path with at most %d bytes", maxUnixSocketPath)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, nil, fmt.Errorf("create socket directory: %w", err)
	}
	lockCleanup, err := acquireSocketLock(path + ".lock")
	if err != nil {
		return nil, nil, err
	}
	releaseLock := true
	defer func() {
		if releaseLock {
			_ = lockCleanup()
		}
	}()
	if err := removeStaleSocket(path); err != nil {
		return nil, nil, err
	}
	// Unix bind applies the process umask when it creates the socket. Hold a
	// package lock so concurrent Listen calls cannot restore the umask early.
	socketUmaskMu.Lock()
	oldUmask := syscall.Umask(0o177)
	listener, err := net.Listen("unix", path)
	syscall.Umask(oldUmask)
	socketUmaskMu.Unlock()
	if err != nil {
		return nil, nil, fmt.Errorf("listen on socket: %w", err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		_ = listener.Close()
		_ = os.Remove(path)
		return nil, nil, fmt.Errorf("set socket permissions: %w", err)
	}
	created, err := os.Lstat(path)
	if err != nil {
		_ = listener.Close()
		return nil, nil, fmt.Errorf("inspect socket: %w", err)
	}
	var cleanupOnce sync.Once
	var cleanupErr error
	cleanup := func() error {
		cleanupOnce.Do(func() {
			_ = listener.Close()
			var socketErr error
			current, err := os.Lstat(path)
			if err == nil && os.SameFile(created, current) {
				socketErr = os.Remove(path)
			} else if err != nil && !errors.Is(err, os.ErrNotExist) {
				socketErr = err
			}
			cleanupErr = errors.Join(socketErr, lockCleanup())
		})
		return cleanupErr
	}
	releaseLock = false
	return listener, cleanup, nil
}

func acquireSocketLock(path string) (func() error, error) {
	socketLockMu.Lock()
	if _, found := socketLocks[path]; found {
		socketLockMu.Unlock()
		return nil, errors.New("socket is already in use")
	}
	socketLocks[path] = struct{}{}
	socketLockMu.Unlock()
	releaseReservation := func() {
		socketLockMu.Lock()
		delete(socketLocks, path)
		socketLockMu.Unlock()
	}

	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		releaseReservation()
		return nil, fmt.Errorf("open socket lock: %w", err)
	}
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = file.Close()
		releaseReservation()
		if errors.Is(err, syscall.EWOULDBLOCK) || errors.Is(err, syscall.EAGAIN) {
			return nil, errors.New("socket is already in use")
		}
		return nil, fmt.Errorf("lock socket: %w", err)
	}
	created, err := file.Stat()
	if err != nil {
		_ = syscall.Flock(int(file.Fd()), syscall.LOCK_UN)
		_ = file.Close()
		releaseReservation()
		return nil, fmt.Errorf("inspect socket lock: %w", err)
	}
	pathInfo, err := os.Lstat(path)
	if err != nil || !created.Mode().IsRegular() || !os.SameFile(created, pathInfo) {
		_ = syscall.Flock(int(file.Fd()), syscall.LOCK_UN)
		_ = file.Close()
		releaseReservation()
		return nil, errors.New("socket lock path is not a regular file")
	}
	var once sync.Once
	var cleanupErr error
	cleanup := func() error {
		once.Do(func() {
			var removeErr error
			current, err := os.Lstat(path)
			if err == nil && os.SameFile(created, current) {
				removeErr = os.Remove(path)
			} else if err != nil && !errors.Is(err, os.ErrNotExist) {
				removeErr = err
			}
			unlockErr := syscall.Flock(int(file.Fd()), syscall.LOCK_UN)
			closeErr := file.Close()
			releaseReservation()
			cleanupErr = errors.Join(removeErr, unlockErr, closeErr)
		})
		return cleanupErr
	}
	return cleanup, nil
}

func removeStaleSocket(path string) error {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("inspect existing socket: %w", err)
	}
	if info.Mode()&os.ModeSocket == 0 {
		return errors.New("socket path exists and is not a Unix socket")
	}
	if err := os.Remove(path); err != nil {
		return fmt.Errorf("remove stale socket: %w", err)
	}
	return nil
}
