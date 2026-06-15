package main

import (
	"errors"
	"os"
	"syscall"
)

func removeSocketIfOwned(address string, owned os.FileInfo) error {
	if owned == nil {
		if err := os.Remove(address); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		return nil
	}

	current, err := os.Stat(address)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	if !sameFileIdentity(owned, current) {
		return nil
	}

	if err := os.Remove(address); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

func sameFileIdentity(a, b os.FileInfo) bool {
	if a == nil || b == nil {
		return false
	}

	aStat, aOK := a.Sys().(*syscall.Stat_t)
	bStat, bOK := b.Sys().(*syscall.Stat_t)
	if !aOK || !bOK {
		return false
	}

	return aStat.Dev == bStat.Dev && aStat.Ino == bStat.Ino
}
