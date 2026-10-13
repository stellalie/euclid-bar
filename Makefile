.PHONY: app run test perf log clean

app:
	scripts/bundle.sh release

run: app
	-pkill -x Euclid
	open build/Euclid.app

test:
	swift test

# Release-mode tests give realistic speed numbers
perf:
	swift test -c release --filter performance

# Live timing for hotkey → visible and keystroke → results
log:
	log stream --level info --predicate 'subsystem == "dev.euclid"'

clean:
	rm -rf .build build
