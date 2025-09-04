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
	return &ConsoleUser{Username: u.Username, UID: st.Uid, HomeDir: u.HomeDir}, nil
}

// intToString removed in favor of strconv.Itoa for clarity and correctness
