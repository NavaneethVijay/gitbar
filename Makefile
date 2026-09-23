.PHONY: gen build run install uninstall update-keys release release-dry clean

DERIVED := build/DerivedData.noindex
XCODEBUILD := xcodebuild -project gitbar.xcodeproj -scheme gitbar -derivedDataPath $(DERIVED)

gen:
	xcodegen generate

build: gen
	$(XCODEBUILD) -configuration Debug build CODE_SIGNING_ALLOWED=NO

run: build
	pkill -x gitbar || true
	open $(DERIVED)/Build/Products/Debug/gitbar.app

# Build a Release copy from this checkout into ~/Applications (or
# INSTALL_DIR=…) and open it. Built locally, so no Gatekeeper prompt.
# Update later with: git pull && make install
install: gen
	INSTALL_DIR="$(INSTALL_DIR)" scripts/install.sh

uninstall:
	pkill -x gitbar || true
	rm -rf "$(or $(INSTALL_DIR),$(HOME)/Applications)/gitbar.app"

# One-time: create the Sparkle EdDSA key (private half stays in your login
# Keychain) and write its public half into project.yml.
update-keys: gen
	$(XCODEBUILD) -resolvePackageDependencies >/dev/null
	scripts/update-keys.sh

# make release VERSION=0.2.0 — build, sign, publish a GitHub release + appcast.
release: gen
	scripts/release.sh $(VERSION)

# Same build/sign/appcast into build/release, but publishes nothing.
release-dry: gen
	DRY_RUN=1 scripts/release.sh $(VERSION)

clean:
	rm -rf build gitbar.xcodeproj
