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

func main() {
	log.Println("PowerGrid Helper started.")

	if os.Geteuid() != 0 {
		log.Fatalln("FATAL: This helper must be run as root.")
	}

	if len(os.Args) < 2 {
		log.Fatalf("FATAL: Missing required argument: 'install' or 'uninstall'.")
	}

	action := os.Args[1]

	switch action {
	case "install":
		if len(os.Args) < 3 {
			log.Fatalln("FATAL: 'install' requires a path to the app resources directory.")
		}
		resourcesPath := os.Args[2]
		log.Printf("Action: install. Using resources path: %s", resourcesPath)
		if err := install(resourcesPath); err != nil {
			log.Fatalf("FATAL: Installation failed: %v", err)
		}
	case "uninstall":
		log.Printf("Action: uninstall.")
		if err := uninstall(); err != nil {
			log.Fatalf("FATAL: Uninstallation failed: %v", err)
		}
	default:
		log.Fatalf("FATAL: Unknown action '%s'. Please use 'install' or 'uninstall'.", action)
	}

	log.Println("PowerGrid Helper finished successfully.")
}

func install(resourcesPath string) error {
	log.Println("--- Starting PowerGrid Daemon Installation ---")

	if _, err := os.Stat(plistInstallPath); err == nil {
		log.Println("Unloading existing service...")
		cmd := exec.Command("launchctl", "unload", plistInstallPath)
		if output, err := cmd.CombinedOutput(); err != nil {
			log.Printf("Warning: 'launchctl unload' failed, but continuing. Output: %s", output)
		}
	}

	sourceDaemon := filepath.Join(resourcesPath, daemonName)
	log.Printf("Copying daemon from %s to %s", sourceDaemon, daemonInstallPath)
	if err := copyFile(sourceDaemon, daemonInstallPath); err != nil {
		return fmt.Errorf("could not copy daemon binary: %w", err)
	}
	if err := os.Chown(daemonInstallPath, 0, 0); err != nil {
		return fmt.Errorf("could not set daemon ownership: %w", err)
	}
	if err := os.Chmod(daemonInstallPath, 0755); err != nil {
		return fmt.Errorf("could not set daemon permissions: %w", err)
	}
	log.Println("✅ Daemon binary installed.")

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

	log.Println("Loading new service with launchctl...")
	cmd := exec.Command("launchctl", "load", plistInstallPath)
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("failed to load service: %s", output)
	}
	log.Println("✅ Service loaded.")

	log.Println("--- Installation Complete ---")
	return nil
}

func uninstall() error {
	log.Println("--- Starting PowerGrid Daemon Uninstallation ---")

	if _, err := os.Stat(plistInstallPath); err == nil {
		log.Println("Unloading service...")
		cmd := exec.Command("launchctl", "unload", plistInstallPath)
		if output, err := cmd.CombinedOutput(); err != nil {
			log.Printf("Warning: 'launchctl unload' failed, but continuing. Output: %s", output)
		}
	} else {
		log.Println("Service plist not found, skipping unload.")
	}
	log.Println("✅ Service unloaded.")

	log.Printf("Removing plist: %s", plistInstallPath)
	if err := os.Remove(plistInstallPath); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("failed to remove plist file: %w", err)
	}
	log.Println("✅ Plist file removed.")

	log.Printf("Removing daemon binary: %s", daemonInstallPath)
	if err := os.Remove(daemonInstallPath); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("failed to remove daemon binary: %w", err)
	}
	log.Println("✅ Daemon binary removed.")

	log.Println("--- Uninstallation Complete ---")
	return nil
}

func copyFile(src, dst string) (err error) {
	sourceFile, err := os.Open(src)
	if err != nil {
		return err
	}
	defer func() {
		if closeErr := sourceFile.Close(); err == nil {
			err = closeErr
		}
	}()

	destFile, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer func() {
		if closeErr := destFile.Close(); err == nil {
			err = closeErr
		}
	}()

	if _, err = io.Copy(destFile, sourceFile); err != nil {
		return err
	}

	return destFile.Sync()
}
