#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
perl_env="$repo_root/AgentScripts/perl_env.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_file() {
    [ -f "$1" ] || fail "missing file: ${1#$repo_root/}"
}

require_path_entry() {
    local path="$1"
    case ":$PERL5LIB:" in
        *":$path:"*) ;;
        *) fail "PERL5LIB missing $path; got $PERL5LIB" ;;
    esac
}

require_file "$perl_env"
require_file "$repo_root/usr/share/perl5/vendor_perl/5.40/LWP/UserAgent.pm"
require_file "$repo_root/lib/perl5/vendor_perl/5.40/x86_64-cygwin-threads/HTML/Parser.pm"

GSP_PERL_ROOT="$repo_root"
export GSP_PERL_ROOT
. "$perl_env"
gsp_configure_bundled_perl

[ "${GSP_PERL_VERSION:-}" = "5.40" ] || fail "unexpected Perl version: ${GSP_PERL_VERSION:-<empty>}"
[ "${GSP_PERL_ARCH:-}" = "x86_64-cygwin-threads" ] || fail "unexpected Perl architecture: ${GSP_PERL_ARCH:-<empty>}"

require_path_entry "/lib/perl5/vendor_perl/5.40/x86_64-cygwin-threads"
require_path_entry "/usr/share/perl5/vendor_perl/5.40"
require_path_entry "/lib/perl5/5.40/x86_64-cygwin-threads"
require_path_entry "/usr/share/perl5/5.40"

lwp_path="$(gsp_perl_module_payload_path LWP::UserAgent || true)"
[ "$lwp_path" = "/usr/share/perl5/vendor_perl/5.40/LWP/UserAgent.pm" ] || \
    fail "LWP::UserAgent resolved to unexpected path: ${lwp_path:-<missing>}"

PERL5LIB="/lib/perl5/vendor_perl/5.40/x86_64-cygwin-threads:/lib/perl5/5.40/x86_64-cygwin-threads"
if gsp_perl_module_payload_path LWP::UserAgent >/dev/null 2>&1; then
    fail "LWP::UserAgent must not resolve when only architecture-specific vendor paths are supplied"
fi

echo "Bundled Perl environment validation passed."
