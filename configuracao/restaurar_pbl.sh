#!/usr/bin/env bash
# Versão bash de configuracao/restaurar_pbl.ps1
#
# Uso:
#   Docker (padrão):  ./configuracao/restaurar_pbl.sh docker --compose docker/compose.yaml
#   Nativo (Linux):   ./configuracao/restaurar_pbl.sh nativo [--porta 5432] [--admin postgres]
#
# Requer o arquivo industria_homologacao_500k.dump na raiz do repositório.

set -euo pipefail

BANCO="pbl_industria_homologacao"
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DUMP="$RAIZ/industria_homologacao_500k.dump"
ACESSO="$RAIZ/configuracao/00_configurar_acesso.sql"

uso() {
    sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 1
}

[[ $# -ge 1 ]] || uso
MODO="$1"; shift

COMPOSE_FILE=""
ADMIN=""
PORTA=5432
while [[ $# -gt 0 ]]; do
    case "$1" in
        --compose) COMPOSE_FILE="$2"; shift 2 ;;
        --admin)   ADMIN="$2"; shift 2 ;;
        --porta)   PORTA="$2"; shift 2 ;;
        *) uso ;;
    esac
done

if [[ ! -f "$DUMP" ]]; then
    echo "Confira se extraiu todo o ZIP e se industria_homologacao_500k.dump está na raiz do kit." >&2
    exit 1
fi

TMP="pbl-restauracao-$(date +%s)-$$"

if [[ "$MODO" == "docker" ]]; then
    [[ -n "$COMPOSE_FILE" ]] || { echo "Informe --compose com o caminho do compose.yaml." >&2; exit 1; }
    COMPOSE_FILE="$(realpath "$COMPOSE_FILE")"
    ADMIN="${ADMIN:-aluno}"
    DC=(docker compose -f "$COMPOSE_FILE")
    PASTA="/tmp/$TMP"
    DUMP_R="$PASTA/base.dump"
    SQL_REST="$PASTA/base.sql"
    SQL_ACESSO="$PASTA/acesso.sql"

    limpar() {
        "${DC[@]}" exec -T db rm -f "$DUMP_R" "$SQL_REST" "$SQL_ACESSO" || true
        "${DC[@]}" exec -T db rmdir "$PASTA" || true
    }
    trap limpar EXIT

    "${DC[@]}" exec -T db mkdir "$PASTA"
    "${DC[@]}" cp "$DUMP" "db:$DUMP_R"
    "${DC[@]}" cp "$ACESSO" "db:$SQL_ACESSO"

    "${DC[@]}" exec -T db pg_restore --no-owner --no-acl --file "$SQL_REST" "$DUMP_R"

    # A criação falha antes de restaurar se o banco já existir.
    "${DC[@]}" exec -T db psql -X -q -U "$ADMIN" -d postgres -v ON_ERROR_STOP=1 \
        -c "CREATE DATABASE $BANCO TEMPLATE template0 ENCODING 'UTF8'"

    echo "Restaurando o banco e configurando pbl_app. Informe a senha local quando solicitada."
    # Sem -T: o psql precisa de terminal para o \password pedir a senha.
    "${DC[@]}" exec db psql -X -q -U "$ADMIN" -d "$BANCO" --single-transaction \
        -v ON_ERROR_STOP=1 -v restauracao_interativa=1 \
        -f "$SQL_REST" -f "$SQL_ACESSO"

elif [[ "$MODO" == "nativo" ]]; then
    ADMIN="${ADMIN:-postgres}"
    CONEXAO=(-h 127.0.0.1 -p "$PORTA")
    PASTA="$(mktemp -d)"
    SQL_REST="$PASTA/base.sql"
    trap 'rm -rf "$PASTA"' EXIT

    pg_restore --no-owner --no-acl --file "$SQL_REST" "$DUMP"

    psql "${CONEXAO[@]}" -X -q -U "$ADMIN" -d postgres -v ON_ERROR_STOP=1 \
        -c "CREATE DATABASE $BANCO TEMPLATE template0 ENCODING 'UTF8'"

    echo "Restaurando o banco e configurando pbl_app. Informe a senha local quando solicitada."
    psql "${CONEXAO[@]}" -X -q -U "$ADMIN" -d "$BANCO" --single-transaction \
        -v ON_ERROR_STOP=1 -v restauracao_interativa=1 \
        -f "$SQL_REST" -f "$ACESSO"
else
    uso
fi

echo "Restauração concluída. Banco: $BANCO. Conta da aplicação: pbl_app."
