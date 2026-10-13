.PHONY: app run test perf log cert clean

app:
	scripts/bundle.sh release

run: app
	-pkill -x euclid-bar
	open build/euclid-bar.app

test:
	swift test

# Release-mode tests give realistic speed numbers
perf:
	swift test -c release --filter performance

# Live timing for hotkey → visible and keystroke → results
log:
	log stream --level info --predicate 'subsystem == "dev.euclid"'

cert:
	scripts/make-dev-cert.sh

clean:
	rm -rf .build build
