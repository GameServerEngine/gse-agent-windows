#!/usr/bin/env bash

# Canonical bundled Perl environment for the Windows agent runtime.

gsp_perl_dir_exists() {
	local path="$1"
	[ -d "${GSP_PERL_ROOT:-}$path" ]
}

gsp_perl_file_exists() {
	local path="$1"
	[ -f "${GSP_PERL_ROOT:-}$path" ]
}

gsp_perl_prepend_path() {
	local path="$1"
	gsp_perl_dir_exists "$path" || return 0
	case ":${GSP_PERL_PATHS:-}:" in
		*":$path:"*) return 0 ;;
	esac
	GSP_PERL_PATHS="${GSP_PERL_PATHS:+$GSP_PERL_PATHS:}$path"
}

gsp_detect_perl_version() {
	local dir base
	for dir in "${GSP_PERL_ROOT:-}"/usr/share/perl5/[0-9]* "${GSP_PERL_ROOT:-}"/lib/perl5/[0-9]*; do
		[ -d "$dir" ] || continue
		base="${dir##*/}"
		case "$base" in
			[0-9]*.[0-9]*) printf '%s\n' "$base"; return 0 ;;
		esac
	done
	return 1
}

gsp_detect_perl_arch() {
	local version="$1"
	local dir base
	for dir in "${GSP_PERL_ROOT:-}"/usr/lib/perl5/"$version"/*-cygwin* "${GSP_PERL_ROOT:-}"/lib/perl5/"$version"/*-cygwin*; do
		[ -d "$dir" ] || continue
		base="${dir##*/}"
		[ -n "$base" ] || continue
		printf '%s\n' "$base"
		return 0
	done
	return 1
}

gsp_configure_bundled_perl() {
	local version="${GSP_PERL_VERSION:-}"
	local arch="${GSP_PERL_ARCH:-}"

	if [ "${GSP_PERL_ORIGINAL_CAPTURED:-0}" != "1" ]; then
		GSP_PERL_ORIGINAL_PERL5LIB="${PERL5LIB:-}"
		GSP_PERL_ORIGINAL_CAPTURED=1
		export GSP_PERL_ORIGINAL_PERL5LIB GSP_PERL_ORIGINAL_CAPTURED
	fi

	if [ -z "$version" ]; then
		version="$(gsp_detect_perl_version)" || {
			printf 'ERROR: could not detect bundled Perl version under /usr/share/perl5 or /lib/perl5.\n' >&2
			return 1
		}
	fi
	if [ -z "$arch" ]; then
		arch="$(gsp_detect_perl_arch "$version")" || {
			printf 'ERROR: could not detect bundled Perl architecture under /usr/lib/perl5/%s or /lib/perl5/%s.\n' "$version" "$version" >&2
			return 1
		}
	fi

	GSP_PERL_VERSION="$version"
	GSP_PERL_ARCH="$arch"
	GSP_PERL_PATHS=""

	gsp_perl_prepend_path "/usr/local/lib/perl5/site_perl/$version/$arch"
	gsp_perl_prepend_path "/usr/local/share/perl5/site_perl/$version"
	gsp_perl_prepend_path "/usr/lib/perl5/site_perl/$version/$arch"
	gsp_perl_prepend_path "/usr/share/perl5/site_perl/$version"
	gsp_perl_prepend_path "/usr/lib/perl5/vendor_perl/$version/$arch"
	gsp_perl_prepend_path "/lib/perl5/vendor_perl/$version/$arch"
	gsp_perl_prepend_path "/usr/share/perl5/vendor_perl/$version"
	gsp_perl_prepend_path "/usr/lib/perl5/$version/$arch"
	gsp_perl_prepend_path "/lib/perl5/$version/$arch"
	gsp_perl_prepend_path "/usr/share/perl5/$version"

	if [ -n "${GSP_PERL_ORIGINAL_PERL5LIB:-}" ]; then
		PERL5LIB="$GSP_PERL_PATHS:$GSP_PERL_ORIGINAL_PERL5LIB"
	else
		PERL5LIB="$GSP_PERL_PATHS"
	fi
	export GSP_PERL_VERSION GSP_PERL_ARCH GSP_PERL_PATHS PERL5LIB
}

gsp_perl_module_relative_path() {
	local module="$1"
	printf '%s.pm\n' "${module//:://}"
}

gsp_perl_module_payload_path() {
	local module="$1"
	local rel path old_ifs
	rel="$(gsp_perl_module_relative_path "$module")"
	old_ifs="$IFS"
	IFS=:
	for path in ${PERL5LIB:-}; do
		IFS="$old_ifs"
		[ -n "$path" ] || continue
		if gsp_perl_file_exists "$path/$rel"; then
			printf '%s/%s\n' "$path" "$rel"
			return 0
		fi
		IFS=:
	done
	IFS="$old_ifs"
	return 1
}

gsp_perl_preflight() {
	local module rel output inc_output
	gsp_configure_bundled_perl || return 1
	for module in JSON::PP Digest::SHA LWP::UserAgent; do
		rel="$(gsp_perl_module_relative_path "$module")"
		output="$(perl "-M$module" -e 'my $rel = shift; print(($INC{$rel} || ""), "\n")' "$rel" 2>&1)" || {
			printf 'ERROR: bundled Perl preflight failed to load %s.\n' "$module" >&2
			printf 'ERROR: PERL5LIB=%s\n' "${PERL5LIB:-}" >&2
			inc_output="$(perl -e 'print join("\n", @INC), "\n"' 2>&1 || true)"
			printf 'ERROR: effective @INC:\n%s\n' "$inc_output" >&2
			printf 'ERROR: module load output:\n%s\n' "$output" >&2
			return 1
		}
		printf 'Bundled Perl module %s loaded from %s\n' "$module" "${output:-<built-in>}"
	done
}
