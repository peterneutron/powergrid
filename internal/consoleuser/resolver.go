package consoleuser

import (
	"os"
	"os/user"
	"strconv"
	"syscall"
)

type ConsoleUser struct {
	Username string
	UID      uint32
	GID      uint32
	HomeDir  string
}

func Current() (*ConsoleUser, error) {
	fi, err := os.Stat("/dev/console")
	if err != nil {
		return nil, err
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		return nil, nil
	}
	if st.Uid == 0 {
		return nil, nil
	}
	u, err := user.LookupId(strconv.Itoa(int(st.Uid)))
	if err != nil {
		return &ConsoleUser{UID: st.Uid}, nil
	}
	gid, err := strconv.Atoi(u.Gid)
	if err != nil {
		return &ConsoleUser{Username: u.Username, UID: st.Uid, HomeDir: u.HomeDir}, nil
	}
	return &ConsoleUser{Username: u.Username, UID: st.Uid, GID: uint32(gid), HomeDir: u.HomeDir}, nil
}

// intToString removed in favor of strconv.Itoa for clarity and correctness
