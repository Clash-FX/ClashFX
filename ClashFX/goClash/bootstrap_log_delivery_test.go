package main

import "testing"

func TestReloadPauseKeepsCoreErrorsWithoutResumingRoutineCallbacks(t *testing.T) {
	for _, level := range []string{"error", "warning", "info", "debug", "silent"} {
		if !shouldForwardCoreLog(false, level) {
			t.Errorf("active logger dropped %s", level)
		}
		if got := shouldForwardCoreLog(true, level); got != (level == "error") {
			t.Errorf("paused logger forward(%s) = %v", level, got)
		}
	}
}
