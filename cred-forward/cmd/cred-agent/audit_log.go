package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
	"syscall"
)

const maxAuditLogSize int64 = 1024 * 1024

type rotatingLogWriter struct {
	path     string
	maxBytes int64
	mu       sync.Mutex
}

func newAuditOutput(path string) (io.Writer, error) {
	if path == "" {
		return os.Stdout, nil
	}
	if !filepath.IsAbs(path) {
		return nil, errors.New("audit log path must be absolute")
	}
	writer := &rotatingLogWriter{path: path, maxBytes: maxAuditLogSize}
	file, _, err := writer.open()
	if err != nil {
		return nil, err
	}
	if err := file.Close(); err != nil {
		return nil, fmt.Errorf("close audit log: %w", err)
	}
	return writer, nil
}

func (writer *rotatingLogWriter) Write(payload []byte) (int, error) {
	writer.mu.Lock()
	defer writer.mu.Unlock()
	if int64(len(payload)) > writer.maxBytes {
		return 0, errors.New("audit record exceeds log size limit")
	}
	file, info, err := writer.open()
	if err != nil {
		return 0, err
	}
	if info.Size() > 0 && info.Size()+int64(len(payload)) > writer.maxBytes {
		if err := file.Close(); err != nil {
			return 0, fmt.Errorf("close audit log before rotation: %w", err)
		}
		if err := os.Rename(writer.path, writer.path+".1"); err != nil {
			return 0, fmt.Errorf("rotate audit log: %w", err)
		}
		file, _, err = writer.open()
		if err != nil {
			return 0, err
		}
	}
	written, writeErr := file.Write(payload)
	closeErr := file.Close()
	return written, errors.Join(writeErr, closeErr)
}

func (writer *rotatingLogWriter) open() (*os.File, os.FileInfo, error) {
	file, err := os.OpenFile(
		writer.path,
		os.O_CREATE|os.O_APPEND|os.O_WRONLY|syscall.O_NOFOLLOW,
		0o600,
	)
	if err != nil {
		return nil, nil, fmt.Errorf("open audit log: %w", err)
	}
	info, err := file.Stat()
	if err != nil {
		_ = file.Close()
		return nil, nil, fmt.Errorf("inspect audit log: %w", err)
	}
	if !info.Mode().IsRegular() {
		_ = file.Close()
		return nil, nil, errors.New("audit log path is not a regular file")
	}
	if err := file.Chmod(0o600); err != nil {
		_ = file.Close()
		return nil, nil, fmt.Errorf("set audit log permissions: %w", err)
	}
	return file, info, nil
}
