// cmd/powergrid-helper/main.go
package main

import (
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
)

const (
	daemonName        = "powergrid-daemon"
	plistName         = "com.neutronstar.powergrid.daemon.plist"
	installDir        = "/usr/local/bin"
	launchDaemonsDir  = "/Library/LaunchDaemons"
	daemonInstallPath = installDir + "/" + daemonName
	plistInstallPath  = launchDaemonsDir + "/" + plistName
)

// main is the entry point for the helper.
// It expects one argument: the path to the main application's Resources directory.
func main() {
	log.Println("PowerGrid Helper started.")

	if os.Geteuid() != 0 {
		log.Fatalln("FATAL: This helper must be run as root.")
	}

	if len(os.Args) < 2 {
		log.Fatalln("FATAL: Missing required argument: path to app resources.")
	}
	resourcesPath := os.Args[1]
	log.Printf("Using resources path: %s", resourcesPath)

	if err := install(); err != nil {
		log.Fatalf("FATAL: Installation failed: %v", err)
	}

	log.Println("PowerGrid Helper finished successfully.")
}

// install performs the installation steps.
func install() error {
	log.Println("--- Starting PowerGrid Daemon Installation ---")
	resourcesPath := os.Args[1]

	// 1. Unload any old version of the service to prevent conflicts
	if _, err := os.Stat(plistInstallPath); err == nil {
		log.Println("Unloading existing service...")
		cmd := exec.Command("launchctl", "unload", plistInstallPath)
		if output, err := cmd.CombinedOutput(); err != nil {
			// Log the error but continue, as it might already be unloaded
			log.Printf("Warning: 'launchctl unload' failed, but continuing. Output: %s", output)
		}
	}

	// 2. Install the new daemon binary
	sourceDaemon := filepath.Join(resourcesPath, daemonName)
	log.Printf("Copying daemon from %s to %s", sourceDaemon, daemonInstallPath)
	if err := copyFile(sourceDaemon, daemonInstallPath); err != nil {
		return fmt.Errorf("could not copy daemon binary: %w", err)
	}
	if err := os.Chown(daemonInstallPath, 0, 0); err != nil { // 0:0 is root:wheel
		return fmt.Errorf("could not set daemon ownership: %w", err)
	}
	if err := os.Chmod(daemonInstallPath, 0755); err != nil {
		return fmt.Errorf("could not set daemon permissions: %w", err)
	}
	log.Println("✅ Daemon binary installed.")

	// 3. Install the new launchd plist
	sourcePlist := filepath.Join(resourcesPath, plistName)
	log.Printf("Copying plist from %s to %s", sourcePlist, plistInstallPath)
	if err := copyFile(sourcePlist, plistInstallPath); err != nil {
		return fmt.Errorf("could not copy plist: %w", err)
	}
	if err := os.Chown(plistInstallPath, 0, 0); err != nil {
		return fmt.Errorf("could not set plist ownership: %w", err)
	}
	if err := os.Chmod(plistInstallPath, 0644); err != nil {
		return fmt.Errorf("could not set plist permissions: %w", err)
	}
	log.Println("✅ launchd plist installed.")

	// 4. Load the new service
	log.Println("Loading new service with launchctl...")
	cmd := exec.Command("launchctl", "load", plistInstallPath)
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("failed to load service: %s", output)
	}
	log.Println("✅ Service loaded.")

	log.Println("--- Installation Complete ---")
	return nil
}

// copyFile copies a file from src to dst.
func copyFile(src, dst string) (err error) {
	sourceFile, err := os.Open(src)
	if err != nil {
		return err
	}
	// The 'defer' now includes an error check within a closure.
	defer func() {
		if closeErr := sourceFile.Close(); err == nil {
			err = closeErr
		}
	}()

	destFile, err := os.Create(dst)
	if err != nil {
		return err
	}
	// Same pattern for the destination file.
	defer func() {
		if closeErr := destFile.Close(); err == nil {
			err = closeErr
		}
	}()

	if _, err = io.Copy(destFile, sourceFile); err != nil {
		return err
	}

	// Finally, sync the file to disk.
	return destFile.Sync()
}
