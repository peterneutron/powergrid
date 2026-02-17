//go:build darwin

package ipc

import (
	"fmt"
	"net"
	"os"
	"syscall"

	"golang.org/x/sys/unix"
)

const (
	SocketMode os.FileMode = 0o660
)

type UIDAddr interface {
	net.Addr
	UID() uint32
}

type peerCredAddr struct {
	base net.Addr
	uid  uint32
}

func (a *peerCredAddr) Network() string {
	if a.base == nil {
		return "unix"
	}
	return a.base.Network()
}

func (a *peerCredAddr) String() string {
	if a.base == nil {
		return fmt.Sprintf("uid=%d", a.uid)
	}
	return fmt.Sprintf("%s uid=%d", a.base.String(), a.uid)
}

func (a *peerCredAddr) UID() uint32 {
	return a.uid
}

type peerCredConn struct {
	net.Conn
	remote net.Addr
}

func (c *peerCredConn) RemoteAddr() net.Addr {
	return c.remote
}

type secureUnixListener struct {
	base *net.UnixListener
}

func (l *secureUnixListener) Accept() (net.Conn, error) {
	conn, err := l.base.AcceptUnix()
	if err != nil {
		return nil, err
	}

	uid, err := unixPeerUID(conn)
	if err != nil {
		_ = conn.Close()
		return nil, err
	}

	return &peerCredConn{
		Conn:   conn,
		remote: &peerCredAddr{base: conn.RemoteAddr(), uid: uid},
	}, nil
}

func (l *secureUnixListener) Close() error {
	return l.base.Close()
}

func (l *secureUnixListener) Addr() net.Addr {
	return l.base.Addr()
}

func unixPeerUID(conn *net.UnixConn) (uint32, error) {
	rawConn, err := conn.SyscallConn()
	if err != nil {
		return 0, err
	}

	var uid uint32
	var sockErr error
	controlErr := rawConn.Control(func(fd uintptr) {
		cred, err := unix.GetsockoptXucred(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERCRED)
		if err != nil {
			sockErr = err
			return
		}
		uid = cred.Uid
	})
	if controlErr != nil {
		return 0, controlErr
	}
	if sockErr != nil {
		return 0, sockErr
	}
	return uid, nil
}

func PrepareSecureSocket(path string) error {
	fi, err := os.Lstat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}

	if fi.Mode()&os.ModeSocket == 0 {
		return fmt.Errorf("refusing to remove non-socket at %s", path)
	}

	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		return fmt.Errorf("failed to inspect socket ownership for %s", path)
	}
	if st.Uid != 0 {
		return fmt.Errorf("refusing to remove socket with unexpected owner uid=%d at %s", st.Uid, path)
	}
	if fi.Mode().Perm() != SocketMode {
		return fmt.Errorf("refusing to remove socket with unexpected permissions %o at %s", fi.Mode().Perm(), path)
	}

	return os.Remove(path)
}

func Listen(path string) (net.Listener, error) {
	if err := PrepareSecureSocket(path); err != nil {
		return nil, err
	}

	lis, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}

	if err := os.Chown(path, 0, 0); err != nil {
		_ = lis.Close()
		return nil, err
	}
	if err := os.Chmod(path, SocketMode); err != nil {
		_ = lis.Close()
		return nil, err
	}

	unixLis, ok := lis.(*net.UnixListener)
	if !ok {
		_ = lis.Close()
		return nil, fmt.Errorf("expected unix listener")
	}

	return &secureUnixListener{base: unixLis}, nil
}

// SetSocketGroupAccess updates the socket group while preserving root ownership and mode.
// This allows the active console user's primary group to open the socket.
func SetSocketGroupAccess(path string, gid uint32) error {
	if err := os.Chown(path, 0, int(gid)); err != nil {
		return err
	}
	if err := os.Chmod(path, SocketMode); err != nil {
		return err
	}
	return nil
}
