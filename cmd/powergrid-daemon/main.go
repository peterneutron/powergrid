package main

import (
	"os"

	"powergrid/internal/daemon/server"
)

// BuildID is stamped at build time via -ldflags "-X main.BuildID=<id>"
var BuildID string
var BuildIDSource string
var BuildDirty string

func main() {
	if err := server.Run(BuildID, BuildIDSource, BuildDirty == "true"); err != nil {
		_, _ = os.Stderr.WriteString(err.Error() + "\n")
		os.Exit(1)
	}
}
