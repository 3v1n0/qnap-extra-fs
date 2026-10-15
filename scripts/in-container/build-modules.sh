#!/usr/bin/env bash
#
# Build one filesystem's kernel modules for QNAP's kernel, inside the build
# container.
#
# The kernel tree is prepared first, configured the way the NAS kernel is: the
# model's .config, the filesystem's overlay, kbuild resolving the selects.
# Then the filesystem's own builder produces the modules and lists them in a
# manifest. Collecting them, working out the load order from modinfo and
# checking the vermagic is the same for every filesystem, so it lives here.
#
# The kernel itself is never built.
#
# Environment (set by scripts/20-make-modules.sh):
#   FS_NAME         filesystem to build, i.e. fs/<name>/fs.mk
#   KERNEL_MAJOR    kernel series in the QNAP tree (default 5.10)
#   TARGET_ARCH     kbuild ARCH= value (default: this machine's)
#   MODEL           QNAP model whose kernel_cfg .config to use
#   KERNEL_RELEASE  expected release string, asserted against the built modules
#   JOBS            parallel build jobs
set -euo pipefail

REPO_DIR=${REPO_DIR:-/work}
KERNEL_MAJOR=${KERNEL_MAJOR:-5.10}
TARGET_ARCH=${TARGET_ARCH:-$(uname -m)}
JOBS=${JOBS:-$(nproc)}
FS_NAME=${FS_NAME:?FS_NAME is required}

log() { printf '==> %s\n' "$*"; }
warn() { printf '!!! %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# shellcheck source=/dev/null
. "$REPO_DIR/fs/$FS_NAME/fs.mk"

SRC="$REPO_DIR/build/src"
TREE="$SRC/GPL_QTS/src/linux-$KERNEL_MAJOR"
CFG_DIR="$SRC/GPL_QTS/kernel_cfg"
DEST="$REPO_DIR/build/modules/$FS_NAME/${KERNEL_RELEASE:?KERNEL_RELEASE is required}"
MANIFEST="$DEST.manifest"

[ -d "$TREE" ] || die "kernel tree not found: $TREE (run ./build.sh fetch first)"

# Which script knows how to build this filesystem's modules.
FS_MODULE_BUILDER=${FS_MODULE_BUILDER:-scripts/in-container/build-kbuild-modules.sh}

# ---------------------------------------------------------------- config ----

prepare_config() {
    local cfg="" changed=0 line sym val missing=""

    if [ -n "${MODEL:-}" ]; then
        # QNAP names these linux-<series>-<arch>.config; glob and prefer the
        # one for the target architecture instead of assuming a name.
        local candidate
        for candidate in "$CFG_DIR/$MODEL"/linux-"$KERNEL_MAJOR"-*.config; do
            [ -f "$candidate" ] || continue
            case "$candidate" in
                *-"$TARGET_ARCH".config) cfg=$candidate; break ;;
            esac
            [ -n "$cfg" ] || cfg=$candidate
        done
        [ -n "$cfg" ] || die "no kernel config for model $MODEL in $CFG_DIR"
        log "using model config: $cfg"
    elif [ -f "$TREE/.config" ]; then
        cfg="$TREE/.config"
        log "using the config shipped in the tree"
    else
        die "no kernel config found (pass MODEL=...)"
    fi

    # Preparing the tree is the slow part (modules_prepare walks the whole
    # source tree), so remember what it was prepared for and skip it when
    # nothing changed.
    local stamp marker="$TREE/.extrafs-prepared-$FS_NAME"
    stamp=$(printf '%s\n%s\n' "$cfg" "${FS_CONFIG_OVERLAY:-}" | sha256sum | cut -d' ' -f1)

    if [ -f "$marker" ] && [ "$(cat "$marker")" = "$stamp" ]; then
        log "kernel tree already prepared for $FS_NAME"
    else
        if [ "$cfg" != "$TREE/.config" ]; then
            log "installing config into the tree"
            cp "$cfg" "$TREE/.config"
            changed=1
        fi

        # Apply the overlay with the kernel's own scripts/config so =y/=m/=n
        # are handled exactly as a developer would. Filesystems that need no
        # kernel option at all (zfs brings its own) have an empty overlay.
        for line in ${FS_CONFIG_OVERLAY:-}; do
            sym=${line%%=*}
            val=${line#*=}
            case "$val" in
                y) "$TREE/scripts/config" --file "$TREE/.config" --enable "${sym#CONFIG_}" ;;
                m) "$TREE/scripts/config" --file "$TREE/.config" --module "${sym#CONFIG_}" ;;
                n) "$TREE/scripts/config" --file "$TREE/.config" --disable "${sym#CONFIG_}" ;;
                *) die "bad overlay line: $line" ;;
            esac
            changed=1
        done

        if [ "$changed" = 1 ]; then
            log "olddefconfig (resolves the selects)"
            make -C "$TREE" ARCH="$TARGET_ARCH" olddefconfig >/dev/null
        fi

        # modules_prepare regenerates include/config and include/generated (what
        # the module Makefiles read) plus scripts/ for the host.
        log "modules_prepare"
        make -C "$TREE" ARCH="$TARGET_ARCH" modules_prepare >/dev/null

        printf '%s\n' "$stamp" > "$marker"
    fi

    if [ -n "${FS_CONFIG_EXPECT:-}" ]; then
        for line in $FS_CONFIG_EXPECT; do
            grep -qx "$line" "$TREE/.config" || missing="$missing $line"
        done
        [ -z "$missing" ] ||
            die "kernel config lacks:$missing (the overlay and its selects did not apply)"
        log "kernel config carries the expected symbols"
    fi
}

# ------------------------------------------------------ dependency closure --

# The module list comes from the filesystem's builder, so a filesystem whose
# modules are produced by an external build system does not have to describe
# them twice. Everything after that is generic.
collect() {
    local ko name dep
    local -a names
    local -A path_of dep_of

    while read -r ko; do
        [ -n "$ko" ] || continue
        [ -f "$ko" ] || die "manifest lists a module that does not exist: $ko"
        name=$(basename "$ko" .ko)
        path_of[$name]=$ko
        names+=("$name")
        dep_of[$name]=$(modinfo -F depends "$ko" 2>/dev/null | tr ',' ' ' || true)
    done < "$MANIFEST"

    [ "${#names[@]}" -gt 0 ] || die "the builder produced no modules"

    # Topological order: a module is emitted once everything it depends on has
    # been. Iterating over the manifest order keeps the result reproducible.
    local -a order
    local emitted=" " ready changed d
    changed=1
    while [ "$changed" = 1 ]; do
        changed=0
        for name in "${names[@]}"; do
            case "$emitted" in *" $name "*) continue ;; esac
            ready=1
            for d in ${dep_of[$name]}; do
                [ -n "${path_of[$d]:-}" ] ||
                    die "$name.ko depends on $d.ko, which this package does not build"
                case "$emitted" in *" $d "*) ;; *) ready=0 ;; esac
            done
            if [ "$ready" = 1 ]; then
                order+=("$name")
                emitted="$emitted$name "
                changed=1
            fi
        done
    done

    mkdir -p "$DEST"
    rm -f "$DEST"/*.ko "$DEST/order"
    for name in "${order[@]}"; do
        install -m 644 "${path_of[$name]}" "$DEST/$name.ko"
    done
    printf '%s\n' "${order[@]}" | sed 's/$/.ko/' > "$DEST/order"

    log "modules in $DEST, load order:"
    sed 's/^/    /' "$DEST/order"

    # The vermagic must match the target kernel exactly; nothing else
    # identifies the ABI on QNAP kernels (CONFIG_MODVERSIONS is off). modinfo
    # pads the value with a trailing space, hence the trimming.
    local expected="$KERNEL_RELEASE SMP mod_unload" got
    for ko in "$DEST"/*.ko; do
        got=$(modinfo -F vermagic "$ko" | sed 's/[[:space:]]*$//')
        [ "$got" = "$expected" ] ||
            die "$(basename "$ko"): vermagic '$got' != expected '$expected'"
    done
    log "vermagic matches '$expected' for all modules"

    # A dependency the kernel provides from vmlinux never shows up here, so an
    # empty dependency list for a module is normal.
    {
        printf '{\n'
        printf '  "filesystem": "%s",\n' "$FS_NAME"
        printf '  "model": "%s",\n' "${MODEL:-tree}"
        printf '  "kernel_release": "%s",\n' "$KERNEL_RELEASE"
        printf '  "kernel_major": "%s",\n' "$KERNEL_MAJOR"
        printf '  "vermagic": "%s"\n' "$expected"
        printf '}\n'
    } > "$DEST/facts.json"
    ( cd "$DEST" && sha256sum ./*.ko | sed 's/^\([0-9a-f]*\)  \.\//\1  /' > SHA256SUMS )
}

# ---------------------------------------------------------------- driver ----

prepare_config

# Guard against a polluted symbol table: the module builds point kbuild at a
# clean one, so a module can never link against a symbol that came from an
# earlier in-tree build rather than from the kernel or from a module this
# repository ships.
pristine="$SRC/Module.symvers.pristine"
if [ -f "$pristine" ]; then
    cp -f "$pristine" "$TREE/Module.symvers"
else
    warn "no pristine Module.symvers recorded, using the tree's own"
fi

log "building modules with $FS_MODULE_BUILDER"
export REPO_DIR FS_NAME KERNEL_MAJOR TARGET_ARCH JOBS MODEL KERNEL_RELEASE
export TREE MODULE_MANIFEST="$MANIFEST"
bash "$REPO_DIR/$FS_MODULE_BUILDER"

[ -s "$MANIFEST" ] || die "$FS_MODULE_BUILDER produced no module list"

collect
rm -f "$MANIFEST"
log "done"
