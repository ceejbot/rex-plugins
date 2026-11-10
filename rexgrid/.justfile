# RexGrid: a floating status grid for Rex panes.

default: test

# Run the core module's tests.
test:
    swift test

# Print what the app reads from the running Rex server, once.
dump:
    swift run RexGrid --dump

# Print the board each time it changes, without the panel. Ctrl-C to stop.
watch:
    swift run RexGrid --watch

# Assemble build/RexGrid.app from a release build.
app:
    #!/bin/sh
    set -eu
    swift build -c release
    app=build/RexGrid.app
    mkdir -p "$app/Contents/MacOS"
    cp "$(swift build -c release --show-bin-path)/RexGrid" "$app/Contents/MacOS/RexGrid"
    cp Support/Info.plist "$app/Contents/Info.plist"
    codesign --force --sign - "$app"
    echo "built $app"

# Build the app and open the panel. Close the panel to quit.
open: app
    open build/RexGrid.app

# Quit a running panel.
quit:
    pkill -x RexGrid || true
