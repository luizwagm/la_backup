#!/bin/bash
# ==========================================================================
#  Diagnostico rapido do backup. Responde a unica pergunta que importa:
#  "se o servidor sumir agora, o que eu tenho?"
# ==========================================================================
set -u
AMBIENTE="${AMBIENTE:-/etc/la-backup.env}"
v() { printf '  \033[32m✔\033[0m %s\n' "$*"; }
x() { printf '  \033[31m✖\033[0m %s\n' "$*"; }
a() { printf '  \033[33m•\033[0m %s\n' "$*"; }

echo ""
echo "  LA Backup — $(date '+%d/%m/%Y %H:%M')"
echo "  ------------------------------------------------------"

[ -r "$AMBIENTE" ] || { x "sem $AMBIENTE — o backup nao esta instalado"; exit 1; }
. "$AMBIENTE"
export RESTIC_REPOSITORY RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
v "destino: $(echo "$RESTIC_REPOSITORY" | sed 's|.*/||') no Cloudflare R2"

# timer
if systemctl is-active --quiet la-backup.timer; then
  # `NextElapseUSecRealtime` vem em MICROSSEGUNDOS desde 1970 — um numero de 16
  # digitos. Impresso cru, era a pergunta "a que horas o backup roda?" respondida
  # com algo que ninguem confere; foi assim que uma troca de horario passou
  # despercebida. Divide por um milhao e vira hora de relogio.
  PROX="$(systemctl show -p NextElapseUSecRealtime --value la-backup.timer 2>/dev/null)"
  case "${PROX:-0}" in
    ''|*[!0-9]*|0) v "timer ligado · proximo disparo nao informado" ;;
    *) v "timer ligado · proximo: $(date -d "@$((PROX / 1000000))" '+%d/%m/%Y as %H:%M' 2>/dev/null || echo "$PROX")" ;;
  esac
else
  x "TIMER PARADO — nao ha backup automatico. sudo systemctl enable --now la-backup.timer"
fi

# ultima execucao
ULT="$(systemctl show -p ExecMainStatus --value la-backup.service 2>/dev/null)"
if [ "${ULT:-0}" = "0" ]; then v "ultima execucao terminou sem erro"
else x "ultima execucao terminou com codigo $ULT — journalctl -u la-backup -n 40"; fi

# o repositorio responde?
if ! restic snapshots >/dev/null 2>&1; then
  x "nao consegui LER o repositorio. Chave errada, rede fora ou bucket apagado."
  exit 1
fi

QUANDO="$(restic snapshots --latest 1 --json | sed -n 's/.*"time":"\([^"]*\)".*/\1/p' | head -1)"
if [ -n "$QUANDO" ]; then
  DIAS=$(( ( $(date +%s) - $(date -d "$QUANDO" +%s 2>/dev/null || echo 0) ) / 86400 ))
  # Dois dias e o limite: com backup diario, tres dias significa que dois
  # falharam calados.
  if [ "$DIAS" -gt 2 ]; then x "o ultimo backup tem $DIAS DIAS"; else v "ultimo backup: ha $DIAS dia(s)"; fi
else
  x "nenhum snapshot no repositorio"
fi

N="$(restic snapshots --json 2>/dev/null | grep -o '"short_id"' | wc -l)"
v "$N snapshots guardados"
echo ""
a "Isto diz que o backup EXISTE. Para saber se ele PRESTA:"
a "    sudo bash /opt/la-backup/restaurar.sh --ensaio"
echo ""
