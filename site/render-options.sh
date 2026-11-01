# Renders the options reference into the book source.
#   render-options.sh OPTIONS_JSON PAGES_JSON MANPAGE_URLS NIXPKGS_REVISION SRC_DIR
# Writes SRC_DIR/<page path> per page, SRC_DIR/options/{search-index.js,options.json} and
# the SUMMARY.md and overview fragments, SRC_DIR/../options-{summary,overview}.md.
set -euo pipefail

options=$1
pages=$2
manpageUrls=$3
revision=$4
src=$5

summary=$src/../options-summary.md
overview=$src/../options-overview.md
: >"$summary"
: >"$overview"

count=$(jq length "$pages")
for ((i = 0; i < count; i++)); do
  page=$(jq -c ".[$i]" "$pages")
  id=$(jq -r .id <<<"$page")
  path=$(jq -r .path <<<"$page")
  n=$(jq '.options | length' <<<"$page")

  jq --argjson page "$page" \
    'with_entries(select(.key as $k | $page.options | index($k)))' \
    "$options" >page.json

  nixos-render-docs options commonmark \
    --manpage-urls "$manpageUrls" \
    --revision "$revision" \
    --anchor-style legacy \
    --anchor-prefix opt- \
    page.json body.md

  {
    printf '# %s\n\n' "$id"
    jq -r '"Declared in " + ([.sources[] | "[" + (.name | ltrimstr("<") | rtrimstr(">")) + "](" + .url + ")"] | join(", ")) + "."' <<<"$page"
    printf '\n'
    cat body.md
  } >"$src/$path"

  printf '  - [%s](%s)\n' "$id" "$path" >>"$summary"
  # shellcheck disable=SC2016 # the backticks are Markdown
  printf '| [`%s`](%s) | %s |\n' "$id" "${path#options/}" "$n" >>"$overview"
done

# The search page's data: one entry per option, in page order.
{
  printf 'window.badgeosOptions = '
  jq --slurpfile pages "$pages" '
    [ $pages[0][] as $page
      | $page.options[] as $name
      | .[$name]
      | {
          name: $name,
          page: ($page.path | sub("\\.md$"; ".html")),
          anchor: ("opt-" + (.loc | map(gsub("[*<> \\[\\]:\"]"; "_")) | join("."))),
          type: .type,
          default: (.default.text // null),
          description: (.description // "")
        }
    ]' "$options"
  printf ';\n'
} >"$src/options/search-index.js"

cp "$options" "$src/options/options.json"
