#!/bin/bash
# ==========================================================================
#  LA BACKUP — cópia de TODOS os projetos para fora do servidor
#
#  Roda como root, uma vez por dia, pelo systemd. Faz, nesta ordem:
#
#    1. descobre o que existe (não usa lista escrita à mão — ver abaixo);
#    2. congela cada banco num diretório de trabalho;
#    3. manda tudo para o Cloudflare R2, CIFRADO, com o restic;
#    4. apaga o diretório de trabalho;
#    5. confere que o snapshot chegou;
#    6. e SÓ ENTÃO limpa as pastas `backups/` dos projetos, deixando a cópia
#       mais recente de cada banco.
#
#  TRÊS DECISÕES QUE VALEM SER LIDAS
#
#  · DESCOBRE, NÃO LISTA. Uma lista de projetos escrita à mão só está certa no
#    dia em que é escrita: o próximo site que você subir não entraria no backup,
#    e ninguém perceberia até precisar dele. Aqui os bancos SQLite saem de um
#    glob e os PostgreSQL saem do próprio catálogo do servidor.
#
#  · CIFRA ANTES DE SAIR DAQUI. Os bancos têm nome, telefone, CPF, endereço e —
#    no BemEstar — dado de paciente. O restic cifra com uma chave que só existe
#    aqui e no seu gerenciador de senhas; a Cloudflare guarda blocos que ela não
#    consegue ler. Sem isso, o backup vira um segundo lugar de onde vazar.
#
#  · O SERVIDOR NÃO APAGA O REPOSITÓRIO. Este script nunca roda `prune`. Ele só
#    escreve lá e, no máximo, esquece referências de snapshot. Quem apaga de
#    verdade é você, da sua máquina, de vez em quando. Somado à trava do bucket
#    no R2, isso é o que faz um servidor invadido não conseguir destruir o
#    backup junto — que é o roteiro de todo ransomware.
#
#    O passo 10 apaga arquivos, mas do DISCO DO SERVIDOR, nunca do repositório,
#    e a distinção é o ponto inteiro: ele tira daqui cópias que já estão lá.
#    Quem tem a chave deste servidor continua sem conseguir remover um byte do
#    histórico no R2 — que é o que importa no dia da invasão. E ele só roda
#    depois de o snapshot ter sido procurado e encontrado: se o envio falhar,
#    nada é apagado, e o servidor termina o dia com tudo o que tinha.
# ==========================================================================
set -euo pipefail

RAIZ_PROJETOS="${RAIZ_PROJETOS:-/var/www/projetos}"
TRABALHO="${TRABALHO:-/var/tmp/la-backup}"
AMBIENTE="${AMBIENTE:-/etc/la-backup.env}"

v() { printf '  \033[32m✔\033[0m %s\n' "$*"; }
a() { printf '  \033[33m•\033[0m %s\n' "$*"; }
x() { printf '  \033[31m✖\033[0m %s\n' "$*"; }

[ -r "$AMBIENTE" ] || { x "não achei $AMBIENTE — rode o instalar.sh"; exit 1; }
# shellcheck disable=SC1090
. "$AMBIENTE"

: "${RESTIC_REPOSITORY:?falta RESTIC_REPOSITORY em $AMBIENTE}"
: "${RESTIC_PASSWORD:?falta RESTIC_PASSWORD em $AMBIENTE}"
: "${AWS_ACCESS_KEY_ID:?falta AWS_ACCESS_KEY_ID em $AMBIENTE}"
: "${AWS_SECRET_ACCESS_KEY:?falta AWS_SECRET_ACCESS_KEY em $AMBIENTE}"
export RESTIC_REPOSITORY RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

echo ""
FALHAS=0

echo "  LA Backup — $(date '+%d/%m/%Y %H:%M:%S')"
echo "  ------------------------------------------------------"

# A pasta de trabalho tem dados em claro por alguns segundos. 0700 e dentro de
# /var/tmp, que não é lido por ninguém além do root.
rm -rf "$TRABALHO"
mkdir -p "$TRABALHO"
chmod 700 "$TRABALHO"
# `trap` e não um `rm` no fim: se o script morrer no meio — disco cheio, rede
# fora, Ctrl+C — os dumps em claro sumiriam mesmo assim.
trap 'rm -rf "$TRABALHO"' EXIT INT TERM

# ------------------------------------------------------------- 1. SQLite
echo ""
echo "  SQLite"
N_SQLITE=0
mkdir -p "$TRABALHO/sqlite"
while IFS= read -r banco; do
  [ -f "$banco" ] || continue

  # É MESMO UM SQLITE? Os 16 primeiros bytes de todo banco SQLite são
  # "SQLite format 3\0". Sem esta conferência, um `.db` que na verdade é outra
  # coisa entraria na lista, falharia no `.backup` e contaria como falha —
  # barulho que esconderia a falha de verdade.
  if [ "$(head -c 15 "$banco" 2>/dev/null)" != "SQLite format 3" ]; then continue; fi

  # O NOME DO ALVO CARREGA O CAMINHO INTEIRO, não só o arquivo.
  # O BemEstar e o Kenósis têm DOIS bancos cada (site.db e gestao.db). Com o
  # nome curto, `Projeto--site.db` de um sobrescreveria o do outro se algum dia
  # dois bancos caírem na mesma pasta — e a perda seria silenciosa.
  REL="${banco#"$RAIZ_PROJETOS"/}"
  ALVO="$TRABALHO/sqlite/$(echo "$REL" | tr '/' '~')"
  PROJ="${REL%%/*}"
  # `.backup` do sqlite3, NUNCA `cp`. Com o WAL ligado — e todos estes bancos
  # estão — copiar o arquivo enquanto alguém escreve produz um banco que ABRE e
  # está corrompido. É o pior tipo de backup: parece que existe.
  if sqlite3 "$banco" ".backup '$ALVO'" 2>/dev/null; then
    # Conferir aqui e não na hora de restaurar. Um banco quebrado descoberto no
    # dia do desastre é um backup que não existiu.
    if [ "$(sqlite3 "$ALVO" 'PRAGMA integrity_check;' 2>&1 | head -1)" = "ok" ]; then
      v "$PROJ/$(basename "$banco")  $(du -h "$ALVO" | cut -f1)"
      N_SQLITE=$((N_SQLITE + 1))
    else
      x "$PROJ/$(basename "$banco") — INTEGRIDADE REPROVADA, não vai no backup"
      rm -f "$ALVO"
      FALHAS=$((FALHAS + 1))
    fi
  else
    x "$PROJ/$(basename "$banco") — não consegui copiar"
    FALHAS=$((FALHAS + 1))
  fi
done < <(
  # PROCURA POR CONTEÚDO, NÃO POR CAMINHO.
  #
  # A primeira versão procurava só em `*/dados/*.db`. Rodando no servidor, ela
  # achou UM banco de dezoito — porque os dezessete outros projetos usam
  # `data/`, e `dados/` foi uma escolha minha no Riacho Solar, feita dois dias
  # antes. Eu tinha escrito "descobre, não lista" no cabeçalho deste arquivo e
  # mesmo assim chutei o nome da pasta; um chute é uma lista de um item só.
  #
  # Agora procura qualquer arquivo de banco em qualquer lugar do projeto, até
  # quatro níveis, e confere pelo cabeçalho se é SQLite de verdade. O nome da
  # pasta deixou de importar.
  #
  # `node_modules` fica de fora porque bibliotecas trazem bancos de teste.
  # `backups` fica de fora DESTA lista porque são dezenas de cópias do mesmo
  # banco e a tela viraria ilegível — mas elas não ficam de fora do backup: têm
  # o passo 4 só para elas, com uma linha por projeto.
  find "$RAIZ_PROJETOS" -maxdepth 4 -type f \
       \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) \
       -not -path '*/node_modules/*' \
       -not -path '*/backups/*' \
       -not -path '*/.git/*' \
       -not -name '*-wal' -not -name '*-shm' \
       2>/dev/null | sort
)
if [ "$N_SQLITE" -eq 0 ]; then
  a "nenhum banco SQLite encontrado"
else
  v "$N_SQLITE bancos SQLite"
fi

# --------------------------------------------------------- 2. PostgreSQL
echo ""
echo "  PostgreSQL"
N_PG=0
mkdir -p "$TRABALHO/postgres"
if command -v psql >/dev/null 2>&1 && systemctl is-active --quiet postgresql 2>/dev/null; then
  # Descobre os bancos no CATÁLOGO, como o usuário `postgres` (autenticação
  # local por par). Assim não preciso da senha de nenhum projeto — e um projeto
  # novo entra no backup sem ninguém editar este arquivo.
  ESPERADOS=0
  while IFS= read -r bd; do
    [ -n "$bd" ] || continue
    ESPERADOS=$((ESPERADOS + 1))
    ALVO="$TRABALHO/postgres/$bd.dump"
    # O REDIRECIONAMENTO É FEITO POR ROOT, NÃO PELO pg_dump.
    #
    # A primeira versão usava `pg_dump -f "$ALVO"`. O `-f` faz o PRÓPRIO
    # pg_dump abrir o arquivo — e ele roda como usuário `postgres`, que não
    # tem permissão de escrever em /var/tmp/la-backup (0700, dono root). Os
    # oito bancos falharam com "could not open output file: Permission
    # denied", mensagem que eu estava jogando fora com 2>/dev/null.
    #
    # Com `> "$ALVO"`, quem cria o arquivo é o shell que já roda como root; o
    # pg_dump só escreve na saída padrão e não precisa de permissão nenhuma.
    #
    # `-Fc` é o formato próprio do pg: comprimido, e restaura tabela a tabela
    # com `pg_restore`. Um .sql de texto obriga a restaurar tudo ou nada.
    if sudo -u postgres pg_dump -Fc "$bd" > "$ALVO" 2>"$TRABALHO/.erro"; then
      v "$bd  $(du -h "$ALVO" | cut -f1)"
      N_PG=$((N_PG + 1))
    else
      # O ERRO VAI PARA A TELA. Engoli-lo foi o que transformou oito falhas em
      # oito linhas que não diziam o que fazer.
      x "$bd — pg_dump falhou:"
      sed 's/^/         /' "$TRABALHO/.erro" | head -3
      rm -f "$ALVO"
      FALHAS=$((FALHAS + 1))
    fi
  done < <(sudo -u postgres psql -Atc \
    "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres' ORDER BY 1" \
    2>/dev/null)
  rm -f "$TRABALHO/.erro"
  if [ "$ESPERADOS" -eq 0 ]; then
    a "nenhum banco PostgreSQL neste servidor"
  elif [ "$N_PG" -lt "$ESPERADOS" ]; then
    x "$N_PG de $ESPERADOS bancos PostgreSQL foram copiados"
  fi
else
  a "PostgreSQL não está no ar aqui — pulando"
fi

# ------------------------------------------------------------- 3. arquivos
# Fotos e anexos que os clientes enviaram. Eles NÃO estão no git, então se o
# disco morrer só existem aqui.
echo ""
echo "  Arquivos enviados"
N_ARQ=0
mkdir -p "$TRABALHO/arquivos"
# O MESMO ERRO DOS BANCOS VALIA AQUI: a versão anterior tinha três caminhos
# chutados (`fotos`, `uploads`, `dados/fotos`) e achou zero pastas no servidor.
# Agora procura por NOME PARCIAL, em qualquer profundidade até três, e pula o
# que é do repositório (as imagens em `assets/` estão no git; anexo de cliente
# não está, e é esse que só existe no disco).
while IFS= read -r pasta; do
  [ -d "$pasta" ] || continue
  # Pasta vazia não vira linha na tela nem pasta no snapshot.
  [ -n "$(ls -A "$pasta" 2>/dev/null)" ] || continue
  REL="${pasta#"$RAIZ_PROJETOS"/}"
  PROJ="${REL%%/*}"
  DEST="$TRABALHO/arquivos/$(echo "$REL" | tr '/' '~')"
  mkdir -p "$DEST"
  # `cp -al` faz LIGAÇÃO RÍGIDA em vez de copiar: não gasta disco nem tempo, e
  # o restic lê o mesmo conteúdo. Numa pasta com milhares de fotos, a diferença
  # é entre segundos e minutos — e entre caber e não caber no /var/tmp.
  if cp -al "$pasta"/. "$DEST"/ 2>/dev/null || cp -a "$pasta"/. "$DEST"/ 2>/dev/null; then
    v "$REL  $(du -sh "$DEST" | cut -f1)"
    N_ARQ=$((N_ARQ + 1))
  else
    x "$REL — não consegui copiar"
    FALHAS=$((FALHAS + 1))
  fi
done < <(
  find "$RAIZ_PROJETOS" -maxdepth 3 -type d \
       \( -iname '*foto*' -o -iname '*upload*' -o -iname '*anexo*' -o -iname '*arquivo*' \
          -o -iname '*imagem*' -o -iname '*midia*' -o -iname '*documento*' \) \
       -not -path '*/node_modules/*' \
       -not -path '*/.git/*' \
       -not -path '*/assets/*' \
       2>/dev/null | sort
)
[ "$N_ARQ" -gt 0 ] || a "nenhuma pasta de arquivos enviados"

# ------------------------------------------- 4. histórico das pastas backups/
#
# Cada projeto faz a PRÓPRIA cópia do banco e guarda em `<projeto>/backups`,
# girando as 30 mais recentes (ver o `backup.js` de cada site). Até a v1.1.0
# essas pastas ficavam de FORA daqui — a busca de SQLite as excluía de
# propósito, para a lista na tela não virar centenas de linhas.
#
# Isso deixava de pé uma diferença que só apareceria no pior dia possível: o
# snapshot tem o banco VIVO de hoje; aquelas pastas têm PONTOS NO TEMPO — como
# o banco estava três semanas atrás, antes de alguém apagar a coluna errada.
# São coisas diferentes, e a segunda não existia em lugar nenhum fora do disco
# do servidor.
#
# Entram aqui num grupo só, com UMA linha por projeto — o motivo de excluí-las
# era a tela, e a tela continua legível. E é esta cópia que AUTORIZA a limpeza
# do passo 10: só apago do servidor o que já provei que subiu.
echo ""
echo "  Histórico local (pastas backups/)"
N_HIST=0
PASTAS_HIST=()
mkdir -p "$TRABALHO/historico"

# A MARCA DE TEMPO EXISTE POR CAUSA DA LIMPEZA, não por causa da cópia.
#
# Os sites gravam a cópia deles a qualquer hora — o `agendarBackups` bate de
# hora em hora. Se um deles escrever um arquivo DEPOIS desta linha, ele não
# está no snapshot que estou montando, e apagá-lo no passo 10 seria destruir a
# única cópia existente. Guardando o instante em que comecei, o passo 10 só
# considera o que já estava aqui. O `- 1` é folga para o arquivo escrito no
# mesmo segundo: na dúvida, o arquivo fica.
MARCA=$(( $(date +%s) - 1 ))

while IFS= read -r pasta; do
  [ -d "$pasta" ] || continue
  [ -n "$(ls -A "$pasta" 2>/dev/null)" ] || continue
  REL="${pasta#"$RAIZ_PROJETOS"/}"
  PROJ="${REL%%/*}"
  DEST="$TRABALHO/historico/$(echo "$REL" | tr '/' '~')"
  mkdir -p "$DEST"
  # `cp -al` de novo: ligação rígida, sem gastar disco. Importa mais aqui do
  # que nos anexos — são dezenas de cópias de banco, e copiar de verdade podia
  # encher o /var/tmp antes de o restic começar.
  if cp -al "$pasta"/. "$DEST"/ 2>/dev/null || cp -a "$pasta"/. "$DEST"/ 2>/dev/null; then
    v "$PROJ  $(ls -1 "$DEST" | wc -l) arquivo(s) · $(du -sh "$DEST" | cut -f1)"
    PASTAS_HIST+=("$pasta")
    N_HIST=$((N_HIST + 1))
  else
    # FALHA DE VERDADE, e não um aviso. Se não consigo levar o histórico para o
    # R2, o passo 10 não pode apagá-lo — e o jeito de garantir isso é este
    # contador, que faz o script sair antes de chegar lá.
    x "$PROJ — não consegui copiar o histórico; nada será limpo hoje"
    FALHAS=$((FALHAS + 1))
  fi
done < <(
  # Nome EXATO `backups`, não `*backup*`. A busca larga pegaria a pasta do
  # próprio LA-Backup se ele um dia for clonado aqui dentro, e a limpeza do
  # passo 10 apagaria os arquivos dele.
  find "$RAIZ_PROJETOS" -maxdepth 3 -type d -name 'backups' \
       -not -path '*/node_modules/*' \
       -not -path '*/.git/*' \
       2>/dev/null | sort
)
[ "$N_HIST" -gt 0 ] || a "nenhuma pasta backups/ nos projetos"

# --------------------------------------------------- 5. o que foi guardado
# Um mapa do que existia no dia. Na hora de restaurar, ele responde "o que era
# para estar aqui?" — pergunta que ninguém consegue responder de memória seis
# meses depois.
{
  echo "# Inventário — $(date -Is)"
  echo "# servidor: $(hostname)"
  echo ""
  echo "## SQLite ($N_SQLITE)"
  ls -la "$TRABALHO/sqlite" 2>/dev/null | tail -n +2 || true
  echo ""
  echo "## PostgreSQL ($N_PG)"
  ls -la "$TRABALHO/postgres" 2>/dev/null | tail -n +2 || true
  echo ""
  echo "## Arquivos ($N_ARQ)"
  du -sh "$TRABALHO"/arquivos/* 2>/dev/null || true
  echo ""
  echo "## Histórico local — pastas backups/ dos projetos ($N_HIST)"
  du -sh "$TRABALHO"/historico/* 2>/dev/null || true
  echo ""
  echo "## Serviços no ar"
  systemctl list-units --type=service --state=running --no-legend --no-pager 2>/dev/null |
    awk '{print $1}' | grep -v '^systemd' || true
} > "$TRABALHO/INVENTARIO.txt"

TOTAL=$((N_SQLITE + N_PG + N_ARQ))
if [ "$TOTAL" -eq 0 ]; then
  x "não encontrei NADA para guardar. Backup abortado — um snapshot vazio"
  x "sobrescreveria a impressão de que existe backup."
  exit 1
fi

# ------------------------------------------------------------- 6. enviar
echo ""
echo "  Enviando para o R2"
if ! restic snapshots >/dev/null 2>&1; then
  a "repositório ainda não existe — criando"
  restic init
fi

# O SNAPSHOT INCOMPLETO É MARCADO COMO TAL.
# Sem esta etiqueta, um backup sem os oito bancos do PostgreSQL fica na lista
# ao lado dos completos, com a mesma cara. No dia da restauração, escolher pelo
# "mais recente" seria escolher justamente o que não tem nada.
ETIQUETA="completo"
[ "$FALHAS" -eq 0 ] || ETIQUETA="INCOMPLETO"

restic backup "$TRABALHO" \
  --tag automatico --tag "$ETIQUETA" \
  --host "$(hostname)" \
  --exclude-caches \
  --compression auto \
  | sed 's/^/     /'

# ------------------------------------------------------- 7. só ESQUECER
# `forget` sem `--prune`: tira as referências de snapshot antigas, e NÃO apaga
# um byte de dado. Quem apaga é você, da sua máquina, com o `podar` do
# restaurar.sh. Se este servidor for invadido, a chave que ele carrega não
# serve para destruir o histórico.
restic forget \
  --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --keep-yearly 3 \
  --tag automatico \
  | sed 's/^/     /'

# --------------------------------------------------------- 8. conferir
echo ""
ULTIMO="$(restic snapshots --latest 1 --json 2>/dev/null | head -c 4000)"
if echo "$ULTIMO" | grep -q '"time"'; then
  v "snapshot no ar: $(echo "$ULTIMO" | sed -n 's/.*"short_id":"\([^"]*\)".*/\1/p' | head -1)"
  v "guardados: $N_SQLITE SQLite · $N_PG PostgreSQL · $N_ARQ pastas · $N_HIST históricos"
else
  x "o snapshot NÃO apareceu no repositório depois do envio."
  exit 1
fi

# ------------------------------------------------- 9. FALHA É FALHA
#
# Esta é a parte que a primeira versão não tinha, e a falta dela foi o pior
# defeito de tudo que escrevi aqui.
#
# Na primeira execução no servidor, os OITO bancos PostgreSQL falharam — entre
# eles o do BemEstar, que tem dado de paciente — e o script terminou com um
# visto verde e a frase "Pronto". O único guarda que existia disparava se NADA
# fosse encontrado; um único SQLite bastou para o backup passar por completo.
#
# Backup parcial que se anuncia como sucesso é PIOR que backup nenhum: com
# backup nenhum a pessoa sabe que está descoberta. Aqui ela dorme tranquila
# achando que tem os bancos, e descobre no dia em que precisa.
#
# O que é enviado continua sendo enviado — meio backup vale mais que zero. O
# que muda é que o código de saída é DIFERENTE DE ZERO, o systemd marca o
# serviço como falho, o `verificar.sh` grita, e o snapshot fica etiquetado.
if [ "$FALHAS" -gt 0 ]; then
  echo ""
  x "══════════════════════════════════════════════════════"
  x "  ESTE BACKUP ESTÁ INCOMPLETO: $FALHAS item(ns) falharam."
  x "  O que deu certo FOI enviado e está no snapshot acima,"
  x "  mas NÃO trate isto como um backup bom."
  x "  Os erros de cada item estão logo acima, na saída."
  x "  Nada foi apagado do servidor."
  x "══════════════════════════════════════════════════════"
  echo ""
  exit 1
fi

# ------------------------------------- 10. LIMPAR O HISTÓRICO DO SERVIDOR
#
# Daqui para baixo, três coisas já são verdade — e é por isso que este trecho
# mora AQUI, e não dentro de um `if` mais acima:
#
#   · nenhum item falhou (o `exit 1` de cima já teria saído);
#   · o `restic backup` terminou sem erro;
#   · o snapshot foi PROCURADO no repositório e apareceu (passo 8).
#
# A segunda depende do `pipefail` lá no alto, e vale saber por quê: o envio é
# `restic backup ... | sed`, e o código de saída de um cano é o do ÚLTIMO
# comando. Sem `pipefail`, o `sed` devolveria zero com o restic tendo falhado,
# o `set -e` não veria nada, e a limpeza apagaria o histórico do servidor por
# causa de um backup que não subiu. É o mesmo tipo de silêncio que fez a v1.0.1
# dizer "Pronto" com oito bancos faltando — só que agora o silêncio apagaria
# arquivo.
#
# A ordem é o guarda. Um `if [ "$FALHAS" -eq 0 ]` no meio do arquivo daria a
# mesma resposta hoje e seria fácil de furar amanhã, com um `continue` novo ou
# uma condição a mais. Estar depois do `exit` é mais difícil de quebrar sem
# perceber.
#
# O QUE FICA: a cópia MAIS RECENTE de cada banco, em cada projeto.
#
# Não é conservadorismo — é o que impede um efeito colateral. O `agendarBackups`
# de cada site decide se está na hora de copiar lendo a DATA dos arquivos desta
# pasta (`ultimaCopia`, no backup.js). Pasta vazia significa "nunca houve
# cópia", e na batida seguinte todo projeto refaria a cópia na hora — inclusive
# um `pg_dump` novo no BemEstar, no Kenósis e no Borda Tudo. Eu esvaziaria a
# pasta às 4h para ela encher de novo às 5h, com um dump a mais por dia de
# custo. Deixando a mais recente, o ciclo de 24h de cada site segue intacto e o
# painel do cliente continua mostrando quando foi a última cópia.
echo ""
echo "  Limpando o histórico já guardado"
APAGADOS=0
BYTES=0
for pasta in ${PASTAS_HIST+"${PASTAS_HIST[@]}"}; do
  REL="${pasta#"$RAIZ_PROJETOS"/}"
  PROJ="${REL%%/*}"
  N_P=0; B_P=0
  # Uma família por banco E por formato: `site` (.db) e `bemestar_gestao`
  # (.sql) são coisas distintas e cada uma guarda a sua mais recente. Sem
  # separar, a cópia do SQLite morreria porque o dump do Postgres é mais novo.
  unset VISTA; declare -A VISTA=()
  while IFS=$'\t' read -r quando tam arq; do
    [ -n "${arq:-}" ] || continue
    NOME="$(basename "$arq")"
    EXT="${NOME##*.}"
    # Tira o carimbo de data do fim do nome para achar a família. Os projetos
    # usam duas convenções — `site.2026-08-04_131414.db` (CW Mendes, Forms,
    # BemEstar) e `site-2026-08-11T20-23-40.db` (Riacho Solar) — e as duas
    # começam num separador seguido do ano. Cortar dali resolve as duas sem
    # precisar de uma lista de projetos, que é justamente o que este projeto
    # inteiro evita.
    FAM="$(printf '%s' "${NOME%.*}" | sed -E 's/[._-][0-9]{4}.*$//')"
    CHAVE="$FAM|$EXT"
    if [ -z "${VISTA[$CHAVE]:-}" ]; then
      VISTA[$CHAVE]=1   # veio ordenado do mais novo para o mais velho: este fica
      continue
    fi
    # NÃO APAGO O QUE CHEGOU DEPOIS DE EU COPIAR. Um site que gravou a cópia
    # dele enquanto o restic subia tem um arquivo que NÃO está no snapshot.
    [ "${quando%.*}" -le "$MARCA" ] || continue
    if rm -f "$arq"; then
      N_P=$((N_P + 1)); B_P=$((B_P + tam))
    fi
  done < <(
    # Só arquivo de banco. Um README, um .gitkeep ou qualquer coisa que alguém
    # tenha deixado na pasta não é backup e não me diz respeito.
    # `-maxdepth 1` e `-type f`: não desço em subpasta e não sigo atalho —
    # um link simbólico apontando para `data/site.db` faria o `rm` acertar o
    # banco vivo.
    find "$pasta" -maxdepth 1 -type f \
         \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \
            -o -name '*.sql' -o -name '*.dump' -o -name '*.gz' -o -name '*.zip' \) \
         -printf '%T@\t%s\t%p\n' 2>/dev/null | LC_ALL=C sort -rn
  )
  if [ "$N_P" -gt 0 ]; then
    v "$PROJ  $N_P arquivo(s) · $((B_P / 1024)) KB liberados"
    APAGADOS=$((APAGADOS + N_P)); BYTES=$((BYTES + B_P))
  else
    a "$PROJ  nada a limpar — só havia a cópia mais recente"
  fi
done
if [ "$APAGADOS" -gt 0 ]; then
  echo ""
  v "$APAGADOS arquivo(s) apagados do servidor · $((BYTES / 1048576)) MB livres"
  v "estão no snapshot acima, com a retenção de 14/8/12/3"
fi
echo ""
