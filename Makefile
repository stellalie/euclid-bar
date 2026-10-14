.PHONY: app run test perf log cert demo icon clean

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

# Re-render the README promo (docs/demo.gif + docs/demo.mp4) from the real panel UI
demo:
	swift build -c release
	$$(swift build -c release --show-bin-path)/euclid-bar --render-demo docs

# Re-render Resources/AppIcon.icns
icon:
	swift build -c release
	$$(swift build -c release --show-bin-path)/euclid-bar --render-icon Resources/AppIcon.icns

cert:
	scripts/make-dev-cert.sh

clean:
	rm -rf .build build
