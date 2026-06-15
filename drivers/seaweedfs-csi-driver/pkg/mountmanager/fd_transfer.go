package mountmanager

import (
	"errors"
	"fmt"
	"net"
	"os"
	"syscall"
)

func sendFileDescriptor(socketPath string, file *os.File) error {
	conn, err := net.DialUnix("unixpacket", nil, &net.UnixAddr{Name: socketPath, Net: "unixpacket"})
	if err != nil {
		return err
	}
	defer conn.Close()

	if file == nil {
		return errors.New("file descriptor source is nil")
	}

	_, _, err = conn.WriteMsgUnix([]byte{1}, syscall.UnixRights(int(file.Fd())), nil)
	return err
}

func receiveExportedFileDescriptor(socketPath string, trigger func() (*TakeoverExportResponse, error)) (*os.File, *TakeoverExportResponse, error) {
	if err := os.Remove(socketPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, nil, fmt.Errorf("remove stale handoff socket: %w", err)
	}

	listener, err := net.ListenUnix("unixpacket", &net.UnixAddr{Name: socketPath, Net: "unixpacket"})
	if err != nil {
		return nil, nil, err
	}
	defer func() {
		_ = listener.Close()
		_ = os.Remove(socketPath)
	}()

	type recvResult struct {
		file *os.File
		err  error
	}
	recvCh := make(chan recvResult, 1)
	go func() {
		file, err := acceptFileDescriptor(listener)
		recvCh <- recvResult{file: file, err: err}
	}()

	resp, err := trigger()
	if err != nil {
		_ = listener.Close()
		result := <-recvCh
		if result.file != nil {
			_ = result.file.Close()
		}
		return nil, nil, err
	}
	if resp == nil {
		_ = listener.Close()
		result := <-recvCh
		if result.file != nil {
			_ = result.file.Close()
		}
		return nil, nil, errors.New("takeover export returned nil response")
	}
	if !resp.Accepted {
		_ = listener.Close()
		result := <-recvCh
		if result.file != nil {
			_ = result.file.Close()
		}
		return nil, resp, nil
	}

	result := <-recvCh
	if result.err != nil {
		return nil, resp, result.err
	}
	return result.file, resp, nil
}

func acceptFileDescriptor(listener *net.UnixListener) (*os.File, error) {
	conn, err := listener.AcceptUnix()
	if err != nil {
		return nil, err
	}
	defer conn.Close()

	var data [4]byte
	control := make([]byte, 4*256)
	_, oobn, _, _, err := conn.ReadMsgUnix(data[:], control)
	if err != nil {
		return nil, err
	}

	msgs, err := syscall.ParseSocketControlMessage(control[:oobn])
	if err != nil {
		return nil, err
	}
	if len(msgs) != 1 {
		return nil, fmt.Errorf("expected 1 socket control message, got %d", len(msgs))
	}

	fds, err := syscall.ParseUnixRights(&msgs[0])
	if err != nil {
		return nil, err
	}
	if len(fds) != 1 {
		return nil, fmt.Errorf("expected 1 inherited fd, got %d", len(fds))
	}
	if fds[0] < 0 {
		return nil, fmt.Errorf("received negative fd %d", fds[0])
	}
	return os.NewFile(uintptr(fds[0]), "seaweedfs-handoff-fd"), nil
}
