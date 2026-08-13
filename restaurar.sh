#!/bin/bash
# ==========================================================================
#  RESTAURAR — e, sobretudo, ENSAIAR a restauração
#
#      bash restaurar.sh --ensaio          confere que o backup PRESTA
#      bash restaurar.sh --listar          mostra os snapshots
#      bash restaurar.sh --conferir [10%]  os bytes no Cloudflare estao integros?
#      bash restaurar.sh --ver <id>        mostra o que tem dentro de um
#      bash restaurar.sh --baixar <id> <pasta>   traz um snapshot para cá
#      bash restaurar.sh --podar           apaga o que a política já esqueceu
#
#  POR QUE O ENSAIO É O COMANDO MAIS IMPORTANTE DAQUI
#
#  Backup que nunca foi restaurado não é backup — é a lembrança de ter
#  configurado um. Os modos de falha silenciosa são todos assim: a chave de
#  cifra que ninguém anotou, o dump que sai truncado porque o disco encheu, o
#  banco copiado com `cp` no meio de uma escrita. Nenhum deles dá erro no dia
#  em que acontece. Todos dão erro no dia em que se precisa.
#
#  O `--ensaio` baixa o último snapshot de verdade, ABRE cada banco e roda
#  `integrity_check` no SQLite e `pg_restore --list` no PostgreSQL. Se ele
#  passar, o backup presta hoje. Rode uma vez por mês.
#
#  O `--podar` é o único comando que APAGA. Ele mora aqui, e não no backup.sh,
#  de propósito: o servidor nunca apaga nada. Rode-o da SUA máquina, com a sua
#  chave, quando quiser recuperar espaço.
# ==========================================================================
set -euo pipefail

AMBIENTE="${AMBIENTE:-/etc/la-backup.env}"
[ -r "$AMBIENTE" ] || { echo "não achei $AMBIENTE"; exit 1; }
# shellcheck disable=SC1090
. "$AMBIENTE"
export RESTIC_REPOSITORY RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

v() { printf '  \033[32m✔\033[0m %s\n' "$*"; }
x() { printf '  \033[31m✖\033[0m %s\n' "$*"; }
a() { printf '  \033[33m•\033[0m %s\n' "$*"; }

case "${1:---ensaio}" in

  --listar)
    restic snapshots
    ;;

  --ver)
    [ -n "${2:-}" ] || { echo "uso: $0 --ver <id>"; exit 1; }
    restic ls -l "$2" | head -80
    ;;

  --baixar)
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || { echo "uso: $0 --baixar <id> <pasta>"; exit 1; }
    mkdir -p "$3"
    restic restore "$2" --target "$3"
    v "restaurado em $3"
    echo ""
    a "os arquivos estão EM CLARO agora. Apague quando terminar."
    ;;

  --conferir)
    # ------------------------------------------------------------------
    # "O QUE ESTÁ NO CLOUDFLARE ESTÁ ÍNTEGRO?"
    #
    # Diferente do `--ensaio`, que pergunta "dá para restaurar?". Este pergunta
    # "os bytes que subiram são os bytes certos?".
    #
    # `restic check` SEM `--read-data` confere só a estrutura: se os índices
    # batem com a lista de arquivos. Ele passa mesmo que um bloco tenha sido
    # corrompido no caminho ou no disco da Cloudflare — porque nem chega a
    # baixar o conteúdo. É o teste que dá falsa tranquilidade.
    #
    # `--read-data-subset` BAIXA uma amostra e recalcula o hash de cada bloco.
    # Se um byte mudou, aparece aqui. 10% por padrão porque conferir tudo todo
    # mês gastaria banda à toa; ao longo de dez meses, a amostra cobre o
    # repositório inteiro.
    # ------------------------------------------------------------------
    FATIA="${2:-10%}"
    echo ""
    echo "  CONFERINDO O QUE ESTÁ NO CLOUDFLARE — $(date '+%d/%m/%Y %H:%M')"
    echo "  ------------------------------------------------------"
    echo "  Baixando $FATIA dos dados e recalculando os hashes."
    echo "  (o resto do repositório é conferido nas próximas execuções)"
    echo ""
    if restic check --read-data-subset="$FATIA" 2>&1 | sed 's/^/     /'; then
      echo ""
      v "estrutura e dados conferem — o que está lá é o que subiu daqui"
    else
      echo ""
      x "O REPOSITÓRIO TEM PROBLEMA. Não confie neste backup."
      x "Rode 'restic check --read-data' (tudo) para ver a extensão."
      exit 1
    fi
    echo ""
    echo "  Quanto está guardado:"
    restic stats --mode raw-data 2>/dev/null | sed 's/^/     /'
    echo ""
    echo "  Por snapshot (o que cada dia realmente contém):"
    restic stats --mode restore-size latest 2>/dev/null | sed 's/^/     /'
    echo ""
    ;;

  --podar)
    echo "  Isto APAGA dados do repositório. É o único comando que apaga."
    echo "  A trava do bucket no R2 impede a remoção do que for recente —"
    echo "  então o que sair daqui já passou do período de retenção."
    read -rp "  Continuar? [digite PODAR]: " C
    [ "$C" = "PODAR" ] || { echo "  parei."; exit 0; }
    restic prune
    v "podado"
    ;;

  --ensaio)
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT INT TERM
    echo ""
    echo "  ENSAIO DE RESTAURAÇÃO — $(date '+%d/%m/%Y %H:%M')"
    echo "  ------------------------------------------------------"

    ID="$(restic snapshots --latest 1 --json | sed -n 's/.*"short_id":"\([^"]*\)".*/\1/p' | head -1)"
    [ -n "$ID" ] || { x "não há nenhum snapshot no repositório"; exit 1; }
    QUANDO="$(restic snapshots --latest 1 --json | sed -n 's/.*"time":"\([^"]*\)".*/\1/p' | head -1)"
    v "último snapshot: $ID  ($QUANDO)"

    # O ENSAIO REPROVA SNAPSHOT INCOMPLETO.
    # Sem este teste, um backup SEM os bancos do PostgreSQL passaria: os SQLite
    # que sobraram abrem perfeitamente, e o ensaio diria "presta". Passar aqui
    # tem de significar "dá para restaurar TUDO", e não "o que sobrou abre".
    if restic snapshots --latest 1 --json | grep -q 'INCOMPLETO'; then
      x "o último snapshot está marcado INCOMPLETO — faltam itens dentro dele."
      x "O que falhou está no log: journalctl -u la-backup -n 60"
      exit 1
    fi

    # IDADE. Um backup de três semanas atrás é um backup que parou de rodar e
    # ninguém viu. Este teste é o que transforma "o timer morreu" em algo
    # visível antes do desastre.
    if command -v date >/dev/null 2>&1; then
      SEG=$(( $(date +%s) - $(date -d "$QUANDO" +%s 2>/dev/null || echo 0) ))
      DIAS=$(( SEG / 86400 ))
      if [ "$DIAS" -gt 2 ]; then
        x "o último backup tem $DIAS DIAS. O timer parou? systemctl status la-backup.timer"
      else
        v "idade: $DIAS dia(s)"
      fi
    fi

    echo ""
    echo "  Baixando para conferir..."
    restic restore "$ID" --target "$TMP" >/dev/null 2>&1
    RAIZ="$(find "$TMP" -type d -name sqlite -o -type d -name postgres | head -1)"
    RAIZ="$(dirname "${RAIZ:-$TMP}")"

    echo ""
    echo "  SQLite"
    N=0; RUIM=0
    for b in "$RAIZ"/sqlite/*.db; do
      [ -f "$b" ] || continue
      R="$(sqlite3 "$b" 'PRAGMA integrity_check;' 2>&1 | head -1)"
      T="$(sqlite3 "$b" "SELECT COUNT(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)"
      if [ "$R" = "ok" ] && [ "$T" -gt 0 ]; then
        v "$(basename "$b")  — abre, íntegro, $T tabelas"
        N=$((N + 1))
      else
        x "$(basename "$b")  — $R"
        RUIM=$((RUIM + 1))
      fi
    done
    [ "$N" -gt 0 ] || a "nenhum SQLite no snapshot"

    echo ""
    echo "  PostgreSQL"
    NP=0
    for d in "$RAIZ"/postgres/*.dump; do
      [ -f "$d" ] || continue
      # `pg_restore --list` LÊ o dump inteiro e imprime o índice. Se o arquivo
      # estiver truncado — disco cheio no meio do dump — falha aqui. É o teste
      # mais barato que prova que o dump não é uma casca.
      if C="$(pg_restore --list "$d" 2>/dev/null | grep -c ';' )" && [ "${C:-0}" -gt 0 ]; then
        v "$(basename "$d")  — dump válido, $C objetos"
        NP=$((NP + 1))
      else
        x "$(basename "$d")  — dump ILEGÍVEL ou truncado"
        RUIM=$((RUIM + 1))
      fi
    done
    [ "$NP" -gt 0 ] || a "nenhum dump PostgreSQL no snapshot"

    echo ""
    if [ -f "$RAIZ/INVENTARIO.txt" ]; then
      v "inventário do dia presente"
      sed -n '1,6p' "$RAIZ/INVENTARIO.txt" | sed 's/^/       /'
    fi

    echo ""
    echo "  ------------------------------------------------------"
    if [ "$RUIM" -gt 0 ]; then
      x "$RUIM item(ns) NÃO restauram. O backup não presta como está."
      exit 1
    fi
    v "$N banco(s) SQLite e $NP dump(s) PostgreSQL abrem e estão íntegros."
    v "Este backup presta. Ensaie de novo no mês que vem."
    echo ""
    ;;

  *)
    sed -n '3,20p' "$0" | sed 's/^# \{0,2\}//'
    ;;
esac
