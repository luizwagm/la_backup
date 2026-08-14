# LA Backup

Cópia diária de **todos os projetos** do servidor para o Cloudflare R2, cifrada
antes de sair daqui.

Cobre, sem lista escrita à mão:

- todo banco **SQLite** de qualquer projeto — achado pelo **conteúdo** do
  arquivo (`SQLite format 3`), não pelo nome da pasta
- todo banco **PostgreSQL** do servidor (descobertos no catálogo)
- as pastas de **arquivos enviados** — anexo, foto, mídia, documento — que não
  estão no git e só existem no disco
- o **histórico** que cada projeto guarda na própria pasta `backups/` — os
  pontos no tempo do banco, que não são a mesma coisa que o banco de hoje
- um **inventário** do dia: o que existia e quais serviços rodavam

Site novo entra sozinho no backup. É o ponto de descobrir em vez de listar: uma
lista só está certa no dia em que é escrita.

> Isto não é teoria. A primeira versão procurava em `*/dados/*.db` e achou **1
> banco de 18** — os outros dezessete projetos usam `data/`, e `dados/` tinha
> sido uma escolha minha num projeto novo. Caminho chutado é lista de um item
> só.

---

## Por que assim

**Cifra do lado de cá.** Os bancos têm nome, telefone, CPF, endereço e — no
BemEstar — dado de paciente. O restic cifra com uma chave que existe só no
servidor e no seu gerenciador de senhas. A Cloudflare guarda blocos que ela não
consegue ler. Sem isso, o backup seria um segundo lugar de onde vazar, e o
problema seria da empresa perante a LGPD.

**O servidor nunca apaga.** O `backup.sh` só escreve. O único comando que apaga
é o `restaurar.sh --podar`, e ele é para você rodar quando quiser. Somado à
trava do bucket, isso é o que impede um servidor invadido de destruir o backup
junto — que é o roteiro de todo ransomware.

**A trava do bucket é o que fecha a porta.** O R2 permite dizer "nada neste
bucket pode ser apagado nem sobrescrito por N dias". Com ela, mesmo alguém com
a chave do servidor na mão não consegue tirar o histórico recente.

**Backup que nunca foi restaurado não é backup.** Por isso existe o `--ensaio`,
e por isso ele é o comando que o instalador manda você rodar no fim.

---

## A limpeza das pastas `backups/`

Roda às 4h, **depois** do backup, e **só quando ele deu certo**.

Cada site faz a própria cópia do banco e guarda em `<projeto>/backups`, girando
as 30 mais recentes. Isso é bom contra `rm` errado e ruim contra disco morto:
a cópia mora no mesmo disco do original. Com o R2 no ar, ela virou espaço
ocupado à toa.

O que acontece, nesta ordem:

1. o histórico daquelas pastas **entra no snapshot** (passo 4 do `backup.sh`);
2. o snapshot é enviado e o script **procura por ele** no repositório;
3. se qualquer coisa falhou, o script sai com erro — **e nada é apagado**;
4. só então cada pasta fica com a **cópia mais recente de cada banco**.

O código da limpeza fica *depois* do `exit 1` da falha, e não dentro de um `if`.
É a mesma regra dita de um jeito que é mais difícil de furar sem perceber.

**Por que sobra a mais recente, em vez de esvaziar.** O `agendarBackups` de cada
site decide se está na hora de copiar lendo a **data dos arquivos dessa pasta**.
Pasta vazia significa "nunca houve cópia": na batida seguinte todos os projetos
copiariam na hora, com um `pg_dump` novo no BemEstar, no Kenósis e no Borda
Tudo. Eu esvaziaria às 4h para encher de novo às 5h, com um dump a mais por dia
de custo. Deixando a mais recente, o ciclo de 24h de cada site segue intacto e o
painel do cliente continua respondendo "quando foi a última cópia".

**O que a limpeza não toca:** arquivo que não é banco (um `LEIA-ME`, um
`.gitkeep`), subpasta, atalho — e nada que tenha sido gravado **depois** do
momento em que o histórico foi copiado, porque esse ainda não está no snapshot.

---

## Instalar

### 1. No Cloudflare, uma vez

1. **R2 → Create bucket.** Nome: `la-backup`. Localização: automática.
2. **R2 → Manage R2 API Tokens → Create API Token**
   - Permissão: **Object Read & Write**
   - Escopo: **somente o bucket `la-backup`** (não "todos os buckets")
   - Guarde o **Access Key ID** e o **Secret Access Key** — o segredo aparece
     uma vez só.
3. **O ID da conta** está no canto do painel do R2 (`Account ID`).

### 2. A trava do bucket

Sem ela, o backup protege contra disco queimado mas não contra invasão. Com um
token que tenha permissão de *editar configuração do R2*:

```sh
curl -X PUT \
  "https://api.cloudflare.com/client/v4/accounts/<ID_DA_CONTA>/r2/buckets/la-backup/lock" \
  -H "Authorization: Bearer <TOKEN_DE_CONFIGURACAO>" \
  -H "Content-Type: application/json" \
  -d '{"rules":[{"id":"retencao-30-dias","enabled":true,
        "condition":{"type":"Age","maxAgeSeconds":2592000}}]}'
```

Trinta dias: um invasor não consegue apagar nada mais novo que isso, e a poda
mensal continua funcionando sobre o que já passou. Confirme no painel do R2
depois — a resposta da API não é prova de que a regra ficou ativa.

### 3. No servidor

```sh
sudo bash instalar.sh
```

Ele pede as quatro coisas do R2, instala o restic, cria o timer **diário das
04:00** e **faz o primeiro backup na hora**, com você olhando — para o erro
aparecer agora e não às quatro da manhã.

Se você deixar a senha de cifra em branco, ele sorteia uma e obriga a confirmar
que foi para o gerenciador de senhas antes de gravar qualquer coisa.

> **Perder a senha de cifra é perder o backup inteiro.** Não há recuperação,
> nem pela Cloudflare, nem por mim. É o mesmo risco do `DADOS_CHAVE` do
> BemEstar. Guarde-a no gerenciador **antes** de continuar.

### 4. O ensaio

```sh
sudo bash /opt/la-backup/restaurar.sh --ensaio
```

Baixa o último snapshot de verdade, abre cada SQLite com `integrity_check` e lê
cada dump do PostgreSQL com `pg_restore --list`. Se passar, o backup presta
hoje. **Rode uma vez por mês.**

---

## Uso

| Comando | O que faz |
|---|---|
| `bash verificar.sh` | o backup existe? de quando é? o timer está de pé? |
| `bash restaurar.sh --ensaio` | o backup **presta**? (abre tudo de verdade) |
| `bash restaurar.sh --listar` | os snapshots guardados |
| `bash restaurar.sh --conferir` | **os bytes no Cloudflare estão íntegros?** baixa 10% e recalcula os hashes |
| `bash restaurar.sh --ver <id>` | o que tem dentro de um snapshot |
| `bash restaurar.sh --baixar <id> <pasta>` | traz um snapshot para o disco |
| `bash restaurar.sh --podar` | **o único que apaga** — recupera espaço |

## Restaurar de verdade, depois do desastre

```sh
# 1. numa máquina nova, com o restic instalado:
export RESTIC_REPOSITORY=s3:https://<CONTA>.r2.cloudflarestorage.com/la-backup
export RESTIC_PASSWORD=<a senha do gerenciador>
export AWS_ACCESS_KEY_ID=<...>
export AWS_SECRET_ACCESS_KEY=<...>

restic snapshots                       # escolha o dia
restic restore <id> --target /tmp/volta

# 2. SQLite: é só copiar o arquivo para dados/ do projeto
cp /tmp/volta/**/sqlite/Riacho-Solar--site.db /var/www/projetos/Riacho-Solar/dados/site.db

# 3. PostgreSQL:
sudo -u postgres createdb bordatudo
sudo -u postgres pg_restore -d bordatudo /tmp/volta/**/postgres/bordatudo.dump
```

O `INVENTARIO.txt` de dentro do snapshot diz o que existia naquele dia e quais
serviços rodavam — a pergunta que ninguém responde de memória seis meses depois.

---

## Retenção e custo

Guarda 14 diários, 8 semanais, 12 mensais e 3 anuais. Como o restic deduplica e
os bancos mudam pouco de um dia para o outro, o segundo backup custa quase nada
em espaço.

O histórico das pastas `backups/` entra por inteiro **uma vez** — no primeiro
backup depois desta versão. Do segundo em diante, aquelas pastas já foram
limpas e só têm a cópia mais recente, então o snapshot do dia volta a ser
pequeno. Os pontos no tempo de julho e agosto ficam guardados **naquele
primeiro snapshot**, sujeitos à retenção abaixo como qualquer outro.

Na escala destes dez projetos, isso cabe folgado nos **10 GB gratuitos do R2**.
O R2 também não cobra taxa de saída, o que importa no dia em que você precisar
baixar tudo — é justamente o dia em que o custo não pode ser uma surpresa.

## Backup incompleto é tratado como FALHA

Se qualquer item não puder ser copiado, o script:

1. imprime o erro real daquele item (não engole a mensagem);
2. envia mesmo assim o que deu certo — meio backup vale mais que zero;
3. etiqueta o snapshot como `INCOMPLETO` e **não limpa nada do servidor**;
4. **sai com código diferente de zero**, então o systemd marca o serviço como
   falho e o `verificar.sh` grita;
5. e o `restaurar.sh --ensaio` **reprova** enquanto o último snapshot estiver
   incompleto — sem isso ele diria "presta", porque os SQLite que sobraram
   abrem perfeitamente.

Isso existe porque a primeira execução no servidor falhou nos oito bancos
PostgreSQL — inclusive o do BemEstar, com dado de paciente — e a versão
anterior terminou com um visto verde e a palavra Pronto. Backup parcial que
se anuncia como sucesso é pior que backup nenhum: sem backup a pessoa sabe que
está descoberta; assim ela dorme tranquila e descobre no dia em que precisa.

## O que ainda não está resolvido

- **Aviso quando falhar.** Hoje, se o backup morrer três noites seguidas, quem
  descobre é quem rodar o `verificar.sh`. O certo é o LA Sentinela — que já
  monitora os sites — passar a olhar a idade do último snapshot e avisar. É o
  próximo passo natural, e não fiz agora para não misturar duas entregas.
- **Uma segunda cópia fora da Cloudflare.** Um backup num lugar só ainda é um
  ponto de falha, menor mas existente. Se quiser, o mesmo `backup.sh` manda
  para dois destinos com poucas linhas.
