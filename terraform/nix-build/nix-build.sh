#!/usr/bin/env bash
set -xefu

declare file attribute nix_options special_args
eval "$(jq -r '@sh "attribute=\(.attribute) file=\(.file) nix_options=\(.nix_options) special_args=\(.special_args)"')"
if [ "${nix_options}" != '{"options":{}}' ]; then
  options=$(echo "${nix_options}" | jq -r '.options | to_entries | map("--option \(.key) \(.value)") | join(" ")')
else
  options=""
fi
if [[ ${special_args-} == "{}" ]]; then
  # no special arguments, proceed as normal
  if [[ -n ${file-} ]] && [[ -e ${file-} ]]; then
    # shellcheck disable=SC2086
    out=$(nix build --no-link --json $options -f "$file" "$attribute")
  else
    # shellcheck disable=SC2086
    out=$(nix build --no-link --json ${options} "$attribute")
  fi
else
  if [[ ${file-} != 'null' ]]; then
    # e.g. config_attribute=config.system.build.toplevel
    config_attribute="${attribute}"
    # inject `special_args` into nixos config's `specialArgs`
    base_config="(import ${file})"
    nix_expr="${base_config}.extendModules { specialArgs = builtins.fromJSON ''${special_args}''; }"
    # use temp file over error 'access to absolute path ... is forbidden in pure eval mode'
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp/}$(basename "$0").XXXXXXXXXXXX")
    mkdir -p "${tmp_dir}"
    tmp_file="${tmp_dir}/wrapper.nix"
    echo "${nix_expr}" > "${tmp_file}"
    # shellcheck disable=SC2086
    out=$(nix build --no-link --json ${options} --file "${tmp_file}" "${config_attribute}")
  else
    # pass the args in a pure fashion by extending the original config
    rest="$(echo "${attribute}" | cut -d "#" -f 2)"
    # e.g. config_path=nixosConfigurations.aarch64-linux.myconfig
    config_path="${rest%.config.*}"
    # e.g. config_attribute=config.system.build.toplevel
    config_attribute="config.${rest#*.config.}"

    # grab flake nar from error message
    flake_rel="$(echo "${attribute}" | cut -d "#" -f 1)"
    # e.g. flake_rel="."
    flake_dir="$(readlink -f "${flake_rel}")"
    if [[ "$flake_dir" =~ ^(\/nix\/store\/[^/]+) ]]; then
      # for paths in the nix store, take the root path
      flake_path="${BASH_REMATCH[1]}"
    else
      # for other paths, `builtins.getFlake` will use git
      flake_path="${flake_dir}"
    fi
    flake_json="$(nix flake prefetch "${flake_path}" --json)"
    flake_nar="$(echo "$flake_json" | jq -r '.hash')"
    store_path="$(echo "${flake_json}" | jq -r '.storePath')"
    # while we have a store path now, for a repo this reflects its root level,
    # so search for the largest child segment yielding a match in that store dir.
    iter_path="${flake_dir}"
  
    while [[ ${iter_path} != "/" ]]; do
      # we recurse from the specified directory up to the root
      parent="$(dirname "${iter_path}")"
      child_segment="${flake_dir//$parent/}/flake.nix"
      # check if segment exists
      if [[ -f "${store_path}${child_segment}" ]]; then
        # if so, record it as our best match
        target_segment="${child_segment}"
      fi
      # continue our recursion
      iter_path="${parent}"
    done
    # substitute variables into the template
    base_config="(builtins.getFlake ''file://${flake_dir}?dir=${target_segment//\/flake.nix/}&narHash=${flake_nar}'').${config_path}"
    # inject `special_args` into nixos config's `specialArgs`
    nix_expr="${base_config}.extendModules { specialArgs = builtins.fromJSON ''${special_args}''; }"
    # shellcheck disable=SC2086
    out=$(nix build --no-link --json ${options} --expr "${nix_expr}" "${config_attribute}")
  fi
fi
printf '%s' "$out" | jq -c '.[].outputs'
