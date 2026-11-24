# Anexo Técnico | Caderno de Fichas de Investigação dos Incidentes

**Projeto:** Investigação e Refatoração de Sistema Legado de Manutenção Industrial  
**Base de Dados:** PostgreSQL 18 (`pbl_industria_testes` / `pbl_industria_homologacao`)  
**Linguagem de Aplicação:** Python 3.11+ / Psycopg 3  
**Data:** 24 de Novembro de 2026  

Este anexo consolida as 13 fichas técnicas individuais decorrentes da investigação dos relatos apresentados pelas equipes de Almoxarifado, Manutenção, Financeiro e TI.

---

## Sumário das Fichas Técnicas

1. [Ficha Técnica INC-001 | Desempenho do Histórico de Movimentações](#ficha-técnica-inc-001)
2. [Ficha Técnica INC-002 | Duas Retiradas para Saldo Insuficiente](#ficha-técnica-inc-002)
3. [Ficha Técnica INC-003 | Divergência de Custos na OS-2026-001](#ficha-técnica-inc-003)
4. [Ficha Técnica INC-004 | Falha Atômica no Encerramento de Ordem de Serviço](#ficha-técnica-inc-004)
5. [Ficha Técnica INC-005 | Inconsistência de Dados Cadastrais de Fornecedor](#ficha-técnica-inc-005)
6. [Ficha Técnica INC-006 | Movimentações com Quantidades Inválidas](#ficha-técnica-inc-006)
7. [Ficha Técnica INC-007 | Concessão Excessiva de Privilégios da Conta pbl_app](#ficha-técnica-inc-007)
8. [Ficha Técnica INC-009 | Reenvio de Arquivo e Duplicação Cumulativa de Estoque](#ficha-técnica-inc-009)
9. [Ficha Técnica INC-010 | Mutabilidade Retroativa do Custo de Ordem Encerrada](#ficha-técnica-inc-010)
10. [Ficha Técnica INC-011 | Transições de Status sem Rastreamento de Auditoria](#ficha-técnica-inc-011)
11. [Ficha Técnica INC-012 | Esgotamento de Recursos por Vazamento de Conexões](#ficha-técnica-inc-012)
12. [Ficha Técnica INC-013 | Omissão de Ordens sem Serviços no Relatório Mensal](#ficha-técnica-inc-013)
13. [Ficha Técnica INC-014 | Distorção do Tempo Médio por Cardinalidade Múltipla](#ficha-técnica-inc-014)

---

<a id="ficha-técnica-inc-001"></a>
## Ficha Técnica | INC-001

### 1. Hipótese e Resultado Esperado
- **Relato:** "À medida que o volume de lançamentos cresceu, consultar o histórico de uma peça ficou mais demorado. A equipe percebe a espera principalmente quando consulta períodos longos."
- **Hipótese:** A ausência de índice composto cobrindo os predicados de filtragem e ordenação (`componente_id`, `momento DESC`, `id DESC`), associada à realização de `JOIN` com tabelas dimensionais antes da aplicação do `LIMIT`, obriga o PostgreSQL a realizar leituras sequenciais paralelas (`Parallel Seq Scan`) sobre toda a tabela de movimentações.
- **Resultado Esperado:** A consulta deve responder em tempo submilissegundo (inferior a 5 ms), independentemente de a tabela possuir 500 mil ou milhões de registros, utilizando varredura direta via índice (`Index Scan`).

### 2. Procedimento de Investigação
1. Identificação do componente de teste com maior volume (`COR-002`) e definição de período amplo de consulta (01/08/2026 a 10/11/2026, limite 100).
2. Avaliação dos índices existentes na tabela `industria.movimentacoes` via catálogo `pg_indexes`.
3. Execução de `EXPLAIN (ANALYZE, BUFFERS)` na consulta original com a base de 500 mil registros.
4. Simulação de crescimento da base para 1 milhão e 2 milhões de movimentações na cópia de trabalho (`pbl_industria_testes`), com reavaliação das estatísticas via `ANALYZE`.
5. Execução de bateria de 5 medições em cada volume e cálculo das medianas dos tempos de execução.
6. Criação experimental do índice composto `idx_mov_componente_momento_id` e posterior reestruturação da consulta aplicando o `LIMIT` antecipadamente.

### 3. Evidências e Resultados
A tabela abaixo sintetiza os tempos observados nos testes experimentais:

| Cenário de Teste | Volume de Movimentações | Operação no Plano de Execução | Tempo Mediano (ms) |
|:---|:---:|:---|:---:|
| Consulta Original Legada | 500.000 | Parallel Seq Scan | 164,669 ms |
| Consulta Original Legada | 1.000.000 | Parallel Seq Scan | 289,437 ms |
| Consulta Original Legada | 2.000.000 | Parallel Seq Scan | 545,096 ms |
| Consulta Original + Índice Composto | 2.000.000 | Bitmap Index Scan / Heap Scan | 1.174,924 ms |
| **Consulta Reestruturada + Índice Composto** | **2.000.000** | **Index Scan (Apenas 100 rows lidas)** | **0,449 ms** |

*Plano de execução otimizado:*
```text
Index Scan using idx_mov_componente_momento_id on movimentacoes m
  Index Cond: ((componente_id = 1) AND (momento >= '2026-08-01') AND (momento < '2026-11-11'))
  Rows Removed by Filter: 0 | Execution Time: 0.374 ms
```

### 4. Conclusão
O incidente foi plenamente confirmado por execução. O tempo cresceu linearmente com o volume na consulta original. A mera criação do índice não foi suficiente na consulta legada porque o PostgreSQL precisava juntar com `depositos` antes de aplicar o limite. A combinação do índice composto com a reestruturação da consulta reduziu a mediana em **99,92%**, confirmando a eficácia da solução.

### 5. Solução Proposta e Validação
- **Solução:** Criar índice composto `CREATE INDEX idx_mov_componente_momento_id ON industria.movimentacoes (componente_id, momento DESC, id DESC);` e reestruturar a query no arquivo `aplicacao/relatorios.py` para isolar a busca em uma CTE/subquery antes de juntar com `depositos`.
- **Validação:** Repetir a consulta com outros componentes e volumes, confirmando uso de `Index Scan` e tempo de resposta inferior a 2 ms.

---

<a id="ficha-técnica-inc-002"></a>
## Ficha Técnica | INC-002

### 1. Hipótese e Resultado Esperado
- **Relato:** "Dois técnicos solicitaram a mesma peça quase ao mesmo tempo. O sistema autorizou as duas retiradas, embora o saldo inicial fosse suficiente para atender apenas uma delas."
- **Hipótese:** Ocorrência de condição de corrida (Race Condition / TOCTOU). A função `retirar_pecas` executa a leitura do saldo com `SELECT` simples sem bloqueio (`FOR UPDATE`), verifica a disponibilidade na aplicação e aguarda um tempo de processamento antes do `UPDATE`. Duas transações concorrentes leem o mesmo saldo positivo antes que qualquer uma debite, aprovando ambas as retiradas e negativando o estoque por ausência de constraint `CHECK`.
- **Resultado Esperado:** O SGBD deve serializar o acesso ao registro de estoque. Em duas solicitações simultâneas concorrentes com saldo insuficiente para ambas, uma deve ser aprovada e a outra imediatamente bloqueada e recusada.

### 2. Procedimento de Investigação
1. Análise do arquivo `aplicacao/operacoes.py` (linhas 41-114).
2. Mapeamento das queries executadas e identificação de falta de `FOR UPDATE` e presença de `time.sleep(tempo_processamento)`.
3. Análise dos metadados da tabela `industria.estoques`, constatando ausência de constraint `CHECK (quantidade >= 0)`.
4. Simulação de concorrência com duas threads paralelas solicitando simultaneamente 8 e 7 unidades de um item cujo saldo era 10 unidades.

### 3. Evidências e Resultados
*Trecho relevante em `aplicacao/operacoes.py`:*
```python
# Leitura desconectada sem lock
cur.execute("SELECT e.deposito_id, e.componente_id, e.quantidade, c.preco_atual ... WHERE d.codigo = %s AND c.codigo = %s")
saldo = cur.fetchone()[2]
if saldo < quantidade: raise ValueError(...)
time.sleep(tempo_processamento) # Janela de vulnerabilidade
cur.execute("UPDATE industria.estoques SET quantidade = quantidade - %s ...")
```

*Resultado da Simulação Concorrente:*
- Saldo Inicial: **10**
- Técnico 1 solicitou 8 un. -> **Autorizado**
- Técnico 2 solicitou 7 un. -> **Autorizado**
- Saldo Final Resultante: **-5** (Inconsistência comprovada).

### 4. Conclusão
O diagnóstico foi sustentado integralmente pela análise do código-fonte e comprovado pela simulação concorrente. A ausência de bloqueio pessimista aliada à validação exclusiva em memória gerou o saldo negativo reportado.

### 5. Solução Proposta e Validação
- **Solução:** 
  1. No banco: `ALTER TABLE industria.estoques ADD CONSTRAINT chk_estoques_quantidade CHECK (quantidade >= 0);`
  2. No código: Utilizar `SELECT ... FOR UPDATE OF e` dentro da mesma transação de débito, ou aplicar `UPDATE ... WHERE quantidade >= %s RETURNING quantidade`.
- **Validação:** Reexecutar as duas threads com a consulta protegida por `FOR UPDATE`. O Técnico 1 conclui com sucesso (saldo passa a 2) e o Técnico 2 recebe exceção de saldo insuficiente, mantendo o saldo em 2.

---

<a id="ficha-técnica-inc-003"></a>
## Ficha Técnica | INC-003

### 1. Hipótese e Resultado Esperado
- **Relato:** "O relatório da OS-2026-001 mostra um valor maior que o apurado pelo financeiro ao conferir as peças utilizadas e os serviços executados."
- **Hipótese:** A consulta `consultar_custo_os` realiza `JOIN` direto entre `ordens_servico`, `itens_ordem` e `servicos_ordem`. Sendo itens e serviços entidades independentes ligadas à OS, o join simultâneo gera um produto cartesiano (fan-out de $M \times N$ linhas), duplicando as somas no `SUM()`. Além disso, a query utiliza o preço de tabela corrente (`c.preco_atual`) em vez do valor unitário aplicado na ordem (`i.valor_unitario_aplicado`).
- **Resultado Esperado:** O custo total da OS deve ser rigorosamente igual à soma das peças (quantidade $\times$ valor unitário aplicado) mais a soma dos valores dos serviços prestados.

### 2. Procedimento de Investigação
1. Inspeção da query SQL em `aplicacao/relatorios.py` (linhas 33-46).
2. Consulta analítica separada de peças da `OS-2026-001` na tabela `itens_ordem`.
3. Consulta analítica separada de serviços da `OS-2026-001` na tabela `servicos_ordem`.
4. Comparação entre a apuração financeira real e o resultado retornado pela query legada.

### 3. Evidências e Resultados
*Consulta legada em `aplicacao/relatorios.py`:*
```sql
SELECT o.numero,
       SUM(i.quantidade * c.preco_atual) + SUM(s.valor) AS total
FROM industria.ordens_servico o
JOIN industria.itens_ordem i ON i.ordem_servico_id = o.id
JOIN industria.componentes c ON c.id = i.componente_id
JOIN industria.servicos_ordem s ON s.ordem_servico_id = o.id
WHERE o.numero = 'OS-2026-001'
GROUP BY o.numero;
```

*Confronto de Valores:*
- Total Real Peças (itens da ordem): R$ 380,00 ($M = 2$ peças)
- Total Real Serviços: R$ 450,00 ($N = 3$ serviços)
- **Custo Real Apurado pelo Financeiro:** **R$ 830,00**
- **Custo Calculado pela Consulta Legada:** **R$ 2.040,00** (Divergência de +R$ 1.210,00 decorrente do produto de 6 linhas).

### 4. Conclusão
Incidente plenamente comprovado. O erro reside na modelagem da consulta SQL que provocou duplicação geométrica das agregações e utilizou preço de catálogo dinâmico.

### 5. Solução Proposta e Validação
- **Solução:** Reestruturar a consulta utilizando CTEs independentes para pré-agregar peças e serviços antes do join com a ordem de serviço, utilizando `valor_unitario_aplicado`.
- **Validação:** Executar a consulta com CTE na OS-2026-001 e constatar valor exato de R$ 830,00.

---

<a id="ficha-técnica-inc-004"></a>
## Ficha Técnica | INC-004

### 1. Hipótese e Resultado Esperado
- **Relato:** "Um técnico recebeu uma mensagem de erro ao encerrar uma ordem. Ao consultar novamente, viu que a ordem constava como encerrada, mas o último serviço não aparecia."
- **Hipótese:** A rotina `encerrar_ordem` quebra o princípio da **Atomicidade (ACID)** ao dividir a operação em dois blocos de conexão distintos (`with conectar() as conn:`): o primeiro comita o encerramento da OS; se ocorrer falha ou queda de rede antes do segundo bloco, o serviço não é inserido, mas o encerramento da OS permanece gravado irreversivelmente no banco.
- **Resultado Esperado:** O encerramento da ordem e o registro do serviço final devem ser estritamente atômicos. Diante de qualquer erro, deve ocorrer rollback total, mantendo a OS com o status anterior.

### 2. Procedimento de Investigação
1. Análise do método `encerrar_ordem` em `aplicacao/operacoes.py` (linhas 117-151).
2. Identificação dos dois blocos `with conectar()` separados por verificação com potencial de falha.
3. Execução da função passando o parâmetro `simular_falha=True` para a `OS-2026-003`.
4. Verificação no banco de dados do status da ordem e da contagem de serviços inseridos.

### 3. Evidências e Resultados
*Trecho de `aplicacao/operacoes.py`:*
```python
# Bloco 1 comitado imediatamente
with conectar() as conn:
    cur.execute("UPDATE industria.ordens_servico SET status = 'ENCERRADA' ...")
if simular_falha:
    raise RuntimeError('O sistema de serviços ficou temporariamente indisponível.')
# Bloco 2 nunca é alcançado em caso de erro
with conectar() as conn:
    cur.execute("INSERT INTO industria.servicos_ordem ...")
```
*Estado no Banco após a Falha Provocada:*
- Status da OS: `ENCERRADA`
- Serviços registrados para a ordem: `0` (Estado inconsistente confirmado).

### 4. Conclusão
Diagnóstico confirmado. A violação de atomicidade na aplicação permite a persistência de estados parciais e inconsistentes no banco de dados.

### 5. Solução Proposta e Validação
- **Solução:** Unificar toda a lógica em um único bloco `with conectar() as conn:` e utilizar um único cursor para executar o `UPDATE` e o `INSERT`.
- **Validação:** Executar o teste com `simular_falha=True`. Constatar que o rollback é disparado pelo bloco de contexto e a OS permanece em `EM_EXECUCAO`.

---

<a id="ficha-técnica-inc-005"></a>
## Ficha Técnica | INC-005

### 1. Hipótese e Resultado Esperado
- **Relato:** "A equipe de compras encontrou nomes e telefones diferentes para o mesmo fornecedor ao comparar o cadastro com a ficha de uma peça."
- **Hipótese:** Violação da **3ª Forma Normal (3FN)**. A tabela `componentes` armazena cópias desnormalizadas de atributos de fornecedor (`fornecedor_nome_cache` e `fornecedor_telefone_cache`). Quando o cadastro oficial em `fornecedores` é atualizado, a tabela `componentes` não é modificada por ausência de rotina ou trigger de sincronização, gerando **anomalia de atualização**.
- **Resultado Esperado:** Os dados de um fornecedor devem ser únicos e consistentes em qualquer visualização ou relatório do sistema.

### 2. Procedimento de Investigação
1. Mapeamento das colunas de `industria.componentes` e `industria.fornecedores`.
2. Execução de consulta cruzada comparando os campos oficiais com os campos de cache.
3. Teste de atualização cadastral de um fornecedor e conferência da ficha da peça.

### 3. Evidências e Resultados
*Consulta de Divergências Existentes:*
```sql
SELECT c.codigo, f.nome AS oficial, c.fornecedor_nome_cache AS na_ficha,
       f.telefone AS tel_oficial, c.fornecedor_telefone_cache AS tel_na_ficha
FROM industria.componentes c
JOIN industria.fornecedores f ON f.id = c.fornecedor_id
WHERE f.nome <> c.fornecedor_nome_cache OR f.telefone <> c.fornecedor_telefone_cache;
```
Foram identificados componentes com dados de fornecedores completamente discrepantes na base homologada.

### 4. Conclusão
Incidente confirmado por análise estrutural e dados da base. A redundância desnormalizada sem controle causou anomalia clássica de atualização.

### 5. Solução Proposta e Validação
- **Solução:** 
  - *Longo Prazo:* Remover as colunas de cache da tabela `componentes` e obter os dados sempre via `JOIN` com `fornecedores`.
  - *Curto Prazo:* Implementar a trigger `trg_sync_fornecedor_componentes` no PostgreSQL para propagar atualizações de `fornecedores` para `componentes`.
- **Validação:** Atualizar dados em `fornecedores` e verificar que a ficha do componente reflete instantaneamente a alteração.

---

<a id="ficha-técnica-inc-006"></a>
## Ficha Técnica | INC-006

### 1. Hipótese e Resultado Esperado
- **Relato:** "Durante uma conferência de estoque, encontramos lançamentos com quantidades incompatíveis com as regras do almoxarifado. Precisamos saber quais registros estão inconsistentes e se o sistema ainda aceita lançamentos desse tipo."
- **Hipótese:** A tabela `movimentacoes` e a tabela `estoques` não possuem constraints declarativas de validação de domínio (`CHECK constraints`) para quantidade e tipo. Lançamentos manuais ou por rotinas externas conseguem persistir quantidades negativas, zero ou tipos incompatíveis.
- **Resultado Esperado:** O SGBD deve recusar terminantemente inserções com quantidades $\le 0$, saldos negativos e tipos fora de `('ENTRADA', 'SAIDA')`.

### 2. Procedimento de Investigação
1. Consulta aos metadados do schema `industria` atestando ausência de restrições `CHECK`.
2. Diagnóstico da base homologada de 500 mil registros buscando quantidades inválidas.
3. Teste de inserção direta no banco via SQL de movimentação com quantidade -15.

### 3. Evidências e Resultados
- A consulta à base de testes identificou registros históricos com quantidades $\le 0$ e saldos negativos em estoques.
- O PostgreSQL aceitou com sucesso o comando `INSERT INTO industria.movimentacoes ... VALUES (..., -15, ...)` gerando novo ID sem erros.

### 4. Conclusão
Incidente confirmado. O SGBD aceitava lançamentos incompatíveis por omissão de constraints no schema.

### 5. Solução Proposta e Validação
- **Solução:** Saneamento prévio das linhas históricas e aplicação de constraints declarativas:
  ```sql
  ALTER TABLE industria.movimentacoes ADD CONSTRAINT chk_movimentacoes_quantidade_positiva CHECK (quantidade > 0);
  ALTER TABLE industria.movimentacoes ADD CONSTRAINT chk_movimentacoes_tipo_valido CHECK (tipo IN ('ENTRADA', 'SAIDA'));
  ALTER TABLE industria.estoques ADD CONSTRAINT chk_estoques_saldo_nao_negativo CHECK (quantidade >= 0);
  ```
- **Validação:** Tentar inserir movimentação com quantidade -5: o SGBD bloqueia a operação retornando `CheckViolation`.

---

<a id="ficha-técnica-inc-007"></a>
## Ficha Técnica | INC-007

### 1. Hipótese e Resultado Esperado
- **Relato:** "A TI suspeita que a conta usada pela aplicação tenha permissões além das necessárias para as rotinas do sistema. Precisamos identificar quais acessos são necessários e quais podem ser revistos."
- **Hipótese:** A configuração inicial em `00_configurar_acesso.sql` concedeu `CREATE ON SCHEMA` e `ALL PRIVILEGES` para `pbl_app`, violando o Princípio do Menor Privilégio e expondo o ambiente a riscos de comandos DDL acidentais e deleções em massa (`TRUNCATE`).
- **Resultado Esperado:** A aplicação deve deter apenas privilégios DML necessários (`SELECT, INSERT, UPDATE`), sem permissões DDL ou permissões de exclusão de históricos.

### 2. Procedimento de Investigação
1. Leitura do script `configuracao/00_configurar_acesso.sql`.
2. Consulta dos privilégios concedidos via `information_schema.table_privileges`.
3. Teste de execução de comandos DDL (`CREATE TABLE / DROP TABLE`) e DML destrutivo com o usuário `pbl_app`.

### 3. Evidências e Resultados
- Confirmou-se concessão de `TRUNCATE`, `DROP`, `CREATE`, `TRIGGER` e `REFERENCES` à conta `pbl_app`.
- A conta `pbl_app` conseguiu criar e remover tabelas no schema de homologação.

### 4. Conclusão
Incidente confirmado. O usuário da aplicação possuía privilégios administrativos perigosos e excessivos.

### 5. Solução Proposta e Validação
- **Solução:** Revogar `CREATE ON SCHEMA` e `ALL PRIVILEGES`. Conceder permissões cirúrgicas por tabela (`SELECT, INSERT, UPDATE`) e revogar expressamente `DELETE` e `TRUNCATE` em `movimentacoes` e `auditoria`.
- **Validação:** Certificar que a aplicação continua executando todas as rotinas normais e que um comando de `TRUNCATE` disparado pela aplicação retorne erro de permissão negada.

---

<a id="ficha-técnica-inc-009"></a>
## Ficha Técnica | INC-009

### 1. Hipótese e Resultado Esperado
- **Relato:** "Um operador reenviou um arquivo já processado. Depois disso, o almoxarifado encontrou movimentações repetidas e diferenças nos saldos."
- **Hipótese:** Falta de idempotência na rotina `importar_csv`. A tabela `importacoes` não possui constraint `UNIQUE (chave_lote)` e o código não valida se o lote já foi processado, inserindo novas linhas e acumulando deltas de saldo em `estoques` a cada reenvio.
- **Resultado Esperado:** O sistema deve reconhecer o reenvio de um lote previamente importado e rejeitar a duplicação, mantendo os saldos estáveis.

### 2. Procedimento de Investigação
1. Análise de `aplicacao/importacao.py` (linhas 14-83).
2. Verificação de unicidade em `industria.importacoes`.
3. Execução consecutiva de importação do arquivo `importacao_exemplo.csv` com a mesma chave `LOTE-EXP-2026-001`.
4. Comparação de saldos antes e após o reenvio.

### 3. Evidências e Resultados
- O reenvio do lote gerou novas linhas em `movimentacoes` e somou novamente os itens em `estoques` (ex: saldo de COR-001 duplicou indevidamente).
- O catálogo de constraints confirmou que `chave_lote` não possuía restrição de unicidade.

### 4. Conclusão
Incidente confirmado por execução. A ausência de unicidade na chave do lote permitiu duplicação física e contábil do inventário.

### 5. Solução Proposta e Validação
- **Solução:** 
  1. No banco: `ALTER TABLE industria.importacoes ADD CONSTRAINT uk_importacoes_chave_lote UNIQUE (chave_lote);`
  2. Na aplicação: Validar se `chave_lote` já existe e rejeitar o reprocessamento antes de ler o CSV.
- **Validação:** Tentar importar o mesmo lote pela segunda vez: o banco deve barrar com `UniqueViolation` e a aplicação deve retornar mensagem de erro amigável, preservando os saldos.

---

<a id="ficha-técnica-inc-010"></a>
## Ficha Técnica | INC-010

### 1. Hipótese e Resultado Esperado
- **Relato:** "Depois que atualizamos o preço de uma peça no cadastro, o valor exibido para a OS-2026-002 mudou. A ordem já estava encerrada."
- **Hipótese:** A consulta `consultar_custo_os` multiplica a quantidade de peças pelo preço de catálogo dinâmico `c.preco_atual` em vez de usar o preço histórico registrado em `i.valor_unitario_aplicado` na tabela `itens_ordem`.
- **Resultado Esperado:** Uma ordem de serviço encerrada deve ter seu custo imutável e imune a alterações posteriores em cadastros de peças.

### 2. Procedimento de Investigação
1. Exame da query em `aplicacao/relatorios.py`.
2. Inspeção da tabela `itens_ordem`, confirmando a existência de `valor_unitario_aplicado`.
3. Emissão do relatório de custo da `OS-2026-002`, alteração do preço da peça no catálogo via `atualizar_preco`, e reemissão do relatório.

### 3. Evidências e Resultados
- Custo inicial da OS-2026-002: R$ 520,00.
- Preço do componente reajustado no catálogo para R$ 999,00.
- Custo recalculado da OS-2026-002 pelo sistema legado: R$ 1.489,00 (Variação indevida comprovada para uma ordem já encerrada).

### 4. Conclusão
Incidente plenamente confirmado. A consulta referenciava a coluna errada no cálculo financeiro.

### 5. Solução Proposta e Validação
- **Solução:** Ajustar a query de custo para utilizar exclusivamente `i.valor_unitario_aplicado`.
- **Validação:** Reajustar o preço da peça no catálogo e emitir novamente o custo da OS: o valor permanece estritamente constante.

---

<a id="ficha-técnica-inc-011"></a>
## Ficha Técnica | INC-011

### 1. Hipótese e Resultado Esperado
- **Relato:** "Uma ordem mudou de status. A supervisão tentou descobrir quem fez a alteração, quando ocorreu e qual era o status anterior, mas não encontrou esse registro."
- **Hipótese:** A tabela `ordens_servico` não possui triggers de auditoria associadas, e a função `atualizar_status` na aplicação realiza `UPDATE` direto sem acionar a tabela `industria.auditoria`.
- **Resultado Esperado:** Toda transição de status em ordens de serviço deve ser interceptada pelo SGBD e registrada de forma infalível na tabela `auditoria`, armazenando status anterior, novo status, usuário e timestamp.

### 2. Procedimento de Investigação
1. Inspeção de triggers no schema `industria` via `information_schema.triggers`.
2. Análise do método `atualizar_status` em `aplicacao/operacoes.py`.
3. Execução de mudança de status da `OS-2026-001` e verificação da tabela `industria.auditoria`.

### 3. Evidências e Resultados
- Foram encontradas zero triggers configuradas no schema `industria`.
- A alteração de status foi executada com sucesso pela aplicação, mas a contagem de registros na tabela `auditoria` permaneceu inalterada.

### 4. Conclusão
Incidente plenamente confirmado. A tabela de auditoria existia no schema, mas estava inativa por ausência de trigger.

### 5. Solução Proposta e Validação
- **Solução:** Criar a trigger `trg_auditoria_ordens_servico_status` no PostgreSQL acionada `AFTER UPDATE OF status ON industria.ordens_servico`, gravando os estados anterior e novo em JSONB.
- **Validação:** Alterar o status de uma ordem e consultar a tabela `auditoria`: a alteração deve constar com todos os metadados requeridos.

---

<a id="ficha-técnica-inc-012"></a>
## Ficha Técnica | INC-012

### 1. Hipótese e Resultado Esperado
- **Relato:** "O indicador funciona nas primeiras consultas. Depois de várias consultas seguidas no mesmo uso da aplicação, a operação começa a falhar."
- **Hipótese:** Vazamento de conexões (connection leak) no módulo `uso_repetido.py`. A função `consultar_indicador_repetidamente` instancia conexões com `conectar()` e as anexa em uma lista em memória sem fechá-las. Ao atingir o teto de 8 conexões pendentes (`MAX_SESSOES_ABERTAS`), a aplicação trava e lança exceção.
- **Resultado Esperado:** A aplicação deve executar consultas repetidas sem reter sessões abertas, liberando imediatamente os recursos no cliente e no PostgreSQL.

### 2. Procedimento de Investigação
1. Análise do arquivo `aplicacao/uso_repetido.py`.
2. Inspeção de conexões abertas no PostgreSQL via `pg_stat_activity`.
3. Execução sequencial de chamadas de 5 iterações no mesmo processo.

### 3. Evidências e Resultados
- Na 8ª execução, o sistema lançou: `RuntimeError: A aplicação atingiu o limite de sessões simultâneas.`
- A consulta a `pg_stat_activity` confirmou 8 sessões abertas em estado `idle` mantidas pela aplicação.

### 4. Conclusão
Incidente plenamente confirmado por execução. Defeito de vazamento de conexões na camada de aplicação.

### 5. Solução Proposta e Validação
- **Solução:** Refatorar o método para utilizar o gerenciador de contexto `with conectar() as conn:`, garantindo que cada conexão seja fechada e liberada logo após o uso.
- **Validação:** Executar 20 consultas repetidas: todas concluem com sucesso e as sessões retidas permanecem em 0.

---

<a id="ficha-técnica-inc-013"></a>
## Ficha Técnica | INC-013

### 1. Hipótese e Resultado Esperado
- **Relato:** "Ao comparar os relatórios de fevereiro e outubro de 2026 com o cadastro, vimos que algumas ordens não apareciam no relatório do mês em que foram abertas. O relatório deve listar todas as ordens abertas naquele mês e contar os serviços executados no mesmo mês. Ordens sem serviços no período devem aparecer com zero."
- **Hipótese:** A consulta SQL do cliente aplicou o filtro de período de execução de serviços (`s.executado_em`) na cláusula `WHERE` em vez de na cláusula `ON` do `LEFT JOIN`. Isso anulou a junção externa para ordens que não possuíam serviços executados no mês, descartando-as do relatório.
- **Resultado Esperado:** Todas as ordens abertas no mês devem ser listadas no relatório, apresentando contagem zero caso não tenham tido serviços executados no período.

### 2. Procedimento de Investigação
1. Análise da consulta SQL fornecida pelo cliente.
2. Apuração independente no banco de todas as ordens abertas em fevereiro/2026 e outubro/2026.
3. Execução da consulta do cliente e confronto de resultados.

### 3. Evidências e Resultados
- A apuração independente localizou ordens abertas em fevereiro de 2026 sem serviços realizados naquele mês.
- A consulta original do cliente omitiu completamente essas ordens do resultado final.
- Ao mover o predicado de tempo dos serviços para o `ON` do `LEFT JOIN`, 100% das ordens abertas apareceram no relatório com contagem zero para as que não possuíam serviços.

### 4. Conclusão
Incidente plenamente confirmado e diagnosticado por apuração independente e testes comparativos.

### 5. Solução Proposta e Validação
- **Solução:** Corrigir a consulta SQL posicionando o filtro temporal dos serviços no `ON` do `LEFT JOIN` e preservando no `WHERE` apenas as datas de abertura da OS.
- **Validação:** Reemitir os relatórios de fevereiro e outubro de 2026 e comparar com a quantidade total de ordens cadastradas: a contagem deve coincidir integralmente.

---

<a id="ficha-técnica-inc-014"></a>
## Ficha Técnica | INC-014

### 1. Hipótese e Resultado Esperado
- **Relato:** "O painel mostra, por setor, o total de unidades de peças consumidas em ordens encerradas e o tempo médio entre abertura e encerramento. Depois de lançar peças em uma ordem já encerrada, a média do setor mudou, embora as ordens e suas datas continuassem iguais. Cada ordem encerrada deve ter o mesmo peso na média, inclusive quando não consumiu peças."
- **Hipótese:** A consulta do painel agrega na mesma query granularidades distintas (ordens de serviço e itens de ordens) via `LEFT JOIN`, calculando `AVG()` sobre as linhas resultantes do join. Uma OS com 5 itens de peças é replicada 5 vezes, tendo seu tempo contabilizado 5 vezes na média. Lançar novas peças em uma ordem encerrada aumenta suas réplicas, distorcendo a média de tempo do setor.
- **Resultado Esperado:** Cada ordem encerrada deve participar com peso exatamente 1 no cálculo da média de tempo do setor, independentemente da quantidade de itens de peças associados.

### 2. Procedimento de Investigação
1. Análise da consulta SQL do cliente para a geração do painel.
2. Identificação da cardinalidade $1:N$ entre ordens e itens.
3. Execução do painel em um setor específico antes e depois da inserção de peças em uma OS já encerrada.

### 3. Evidências e Resultados
- Setor Usinagem antes da inserção de peças: Tempo Médio = **4,1200 horas**.
- Inserção de 2 novos itens de peças em uma OS já encerrada do setor, sem alteração de datas.
- Setor Usinagem recalculado pela consulta do cliente: Tempo Médio = **4,3850 horas** (Distorção confirmada).

### 4. Conclusão
Incidente confirmado por experimentação e fundamentação matemática. A mistura de granularidades em joins agrupados corrompe funções agregadoras como `AVG()`.

### 5. Solução Proposta e Validação
- **Solução:** Segregar a agregação em dois níveis: pré-agregar as peças por ordem de serviço em uma CTE (`WITH pecas_por_ordem AS (...)`) e posteriormente realizar a junção 1:1 com as ordens encerradas no agrupamento por setor.
- **Validação:** Inserir novas peças em ordens encerradas: o total de peças aumenta corretamente e o tempo médio setorial permanece rigorosamente idêntico.
