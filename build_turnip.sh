GOOD="e5f4bd529e"
BAD="d005f7baff"

git rev-parse --git-dir >/dev/null 2>&1 || {
    echo "Execute dentro do repositório do Mesa."
    exit 1
}

git log \
    --reverse \
    --ancestry-path \
    "$GOOD..$BAD" \
    --pretty=format:'Commit: %H%nData: %ad%nAutor: %an%nTítulo: %s%n' \
    --date=iso \
    --grep='^tu:' \
    --grep='freedreno' \
    --grep='a6xx' \
    --grep='turnip' \
    --grep='ir3' \
    --grep='fd' \
    --extended-regexp \
> commits_freedreno.txt

echo "Gerado: commits_freedreno.txt ($(grep -c '^Commit:' commits_freedreno.txt) commits)"
