curl -s 'https://api.github.com/repos/be5invis/Iosevka/releases/latest' \
  | jq -r ".assets[] | .browser_download_url" \
  | grep PkgTTC-Iosevka \
  | xargs -n 1 curl -L -O --fail --silent --show-error
