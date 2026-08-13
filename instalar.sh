#!/bin/bash
# ==========================================================================
#  Instala o backup no servidor. RODA COMO ROOT, uma vez.
#      sudo bash instalar.sh
#
#  Pede as quatro coisas do R2, guarda em /etc/la-backup.env com permissao 600,
#  instala o restic, cria o timer diario e FAZ O PRIMEIRO BACKUP na hora — para
#  o erro aparecer agora, com voce olhando, e nao as tres da manha.
# ==========================================================================
set -euo pipefail
[ "$(id -u)" = "0" ] || { echo "rode como root"; exit 1; }

DESTINO="/opt/la-backup"
AMBIENTE="/etc/la-backup.env"

echo ""
echo "  Instalador do LA Backup"
echo "  ======================="

# ------------------------------------------------------------ 1. restic
if command -v restic >/dev/null 2>&1; then
  echo "  restic ja instalado: $(restic version | head -1)"
else
  echo "  instalando restic..."
  apt-get update -qq && apt-get install -y -qq restic
  # O restic do apt costuma ser antigo. `self-update` traz a versao atual, e o
  # formato de repositorio mudou entre versoes — usar uma velha hoje significa
  # nao conseguir ler o repositorio numa maquina nova depois.
  restic self-update >/dev/null 2>&1 || true
  echo "  restic $(restic version | head -1)"
fi
command -v sqlite3 >/dev/null 2>&1 || apt-get install -y -qq sqlite3

# ------------------------------------------------------------ 2. segredos
if [ -f "$AMBIENTE" ]; then
  echo ""
  echo "  $AMBIENTE ja existe — nao vou sobrescrever."
  echo "  Para trocar algo, edite o arquivo e rode este instalador de novo."
else
  echo ""
  echo "  Preciso de quatro coisas do Cloudflare R2."
  echo "  (o README explica onde achar cada uma)"
  echo ""
  read -rp "  ID da conta Cloudflare: " CONTA
  read -rp "  Nome do bucket: " BUCKET
  read -rp "  Access Key ID: " CHAVE_ID
  read -rsp "  Secret Access Key: " CHAVE_SEGREDO; echo ""
  echo ""
  echo "  Agora a SENHA DE CIFRA do repositorio."
  echo "  ATENCAO: perder esta senha e perder o backup. Nao ha recuperacao."
  echo "  Guarde-a no seu gerenciador de senhas ANTES de continuar."
  read -rsp "  Senha de cifra (deixe vazio para eu sortear uma): " SENHA; echo ""
  if [ -z "$SENHA" ]; then
    SENHA="$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 40)"
    echo ""
    echo "  ┌────────────────────────────────────────────────────────────┐"
    echo "  │  SENHA SORTEADA — copie AGORA para o gerenciador de senhas │"
    echo "  ├────────────────────────────────────────────────────────────┤"
    printf "  │  %-58s│\n" "$SENHA"
    echo "  └────────────────────────────────────────────────────────────┘"
    echo ""
    read -rp "  Digitei ela no gerenciador de senhas [digite SIM]: " CONFIRMA
    [ "$CONFIRMA" = "SIM" ] || { echo "  parei. Nada foi gravado."; exit 1; }
  fi

  umask 077
  cat > "$AMBIENTE" <<ENV
# LA Backup — segredos. NAO versionar, NAO copiar para lugar nenhum.
# Perder RESTIC_PASSWORD e perder o backup inteiro.
RESTIC_REPOSITORY=s3:https://$CONTA.r2.cloudflarestorage.com/$BUCKET
RESTIC_PASSWORD=$SENHA
AWS_ACCESS_KEY_ID=$CHAVE_ID
AWS_SECRET_ACCESS_KEY=$CHAVE_SEGREDO
ENV
  chmod 600 "$AMBIENTE"
  echo "  segredos em $AMBIENTE (600)"
fi

# ------------------------------------------------------------ 3. scripts
mkdir -p "$DESTINO"
cp backup.sh restaurar.sh verificar.sh "$DESTINO"/
chmod 755 "$DESTINO"/*.sh
echo "  scripts em $DESTINO"

# ------------------------------------------------------------ 4. timer
cp systemd/la-backup.service systemd/la-backup.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now la-backup.timer
echo "  timer diario ligado: $(systemctl show -p NextElapseUSecRealtime --value la-backup.timer)"

# ------------------------------------------------------------ 5. agora
echo ""
echo "  Primeiro backup, agora, com voce olhando:"
echo "  ------------------------------------------------------"
bash "$DESTINO/backup.sh"

echo ""
echo "  ======================================================"
echo "  Pronto. Falta UMA coisa, e ela e a que separa backup de"
echo "  ilusao de backup:"
echo ""
echo "      sudo bash $DESTINO/restaurar.sh --ensaio"
echo ""
echo "  Ele baixa o ultimo snapshot e confere que os bancos abrem."
echo "  Backup que nunca foi restaurado nao e backup."
echo ""
