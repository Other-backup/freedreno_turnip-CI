#!/bin/bash -e
set -o pipefail

green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

deps="git"
workdir="$(pwd)/turnip_workdir"
mesa_dir="$workdir/mesa"

GOOD_COMMIT="e5f4bd529e"
BAD_COMMIT="d005f7baff"

OUTPUT_FILE="$workdir/commits_freedreno.txt"

check_deps() {
    echo -e "${green}A verificar dependências...${nocolor}"

    for dep in $deps; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            echo -e "${red}Falta a dependência: $dep${nocolor}"
            exit 1
        fi
    done
}

prepare_repo() {
    mkdir -p "$workdir"

    if [ ! -d "$mesa_dir/.git" ]; then
        echo -e "${green}A clonar o Mesa...${nocolor}"

        git clone \
            "https://gitlab.freedesktop.org/mesa/mesa.git" \
            "$mesa_dir"
    else
        echo -e "${green}A usar o repositório Mesa existente...${nocolor}"

        git -C "$mesa_dir" reset --hard
        git -C "$mesa_dir" clean -fd
        git -C "$mesa_dir" fetch origin main
    fi

    cd "$mesa_dir"

    if git rev-parse --is-shallow-repository | grep -q '^true$'; then
        echo -e "${green}A baixar o histórico completo...${nocolor}"
        git fetch --unshallow origin main
    else
        git fetch origin main
    fi
}

check_commits() {
    if ! git cat-file -e "${GOOD_COMMIT}^{commit}" 2>/dev/null; then
        echo -e "${red}Commit GOOD não encontrado: $GOOD_COMMIT${nocolor}"
        exit 1
    fi

    if ! git cat-file -e "${BAD_COMMIT}^{commit}" 2>/dev/null; then
        echo -e "${red}Commit BAD não encontrado: $BAD_COMMIT${nocolor}"
        exit 1
    fi

    if ! git merge-base --is-ancestor "$GOOD_COMMIT" "$BAD_COMMIT"; then
        echo -e "${red}$GOOD_COMMIT não é ancestral de $BAD_COMMIT.${nocolor}"
        exit 1
    fi
}

generate_txt() {
    echo -e "${green}A gerar lista de commits...${nocolor}"

    {
        echo "Commits possivelmente relacionados ao Turnip/Freedreno"
        echo
        echo "Sem regressão: $GOOD_COMMIT"
        echo "Com regressão: $BAD_COMMIT"
        echo
        echo "Filtros:"
        echo "  tu:"
        echo "  freedreno"
        echo "  a6xx"
        echo
        echo "============================================================"
        echo

        git log \
            --reverse \
            --ancestry-path \
            "${GOOD_COMMIT}..${BAD_COMMIT}" \
            --regexp-ignore-case \
            --extended-regexp \
            --grep='(^|[[:space:]])tu:' \
            --grep='freedreno' \
            --grep='a6xx' \
            --pretty=format:'Commit: %H%nCommit curto: %h%nData: %ad%nAutor: %an <%ae>%nTítulo: %s%n' \
            --date=iso

        echo
    } > "$OUTPUT_FILE"

    local count
    count="$(grep -c '^Commit:' "$OUTPUT_FILE" || true)"

    echo -e "${green}Concluído.${nocolor}"
    echo -e "${green}Arquivo: $OUTPUT_FILE${nocolor}"
    echo -e "${green}Commits encontrados: $count${nocolor}"
}

run_all() {
    check_deps
    prepare_repo
    check_commits
    generate_txt
}

run_all
