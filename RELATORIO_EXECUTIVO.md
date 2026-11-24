# Relatório Executivo | Investigação e Plano de Correção do Sistema Legado

**Para:** Diretoria de Operações, Gestão Industrial e Gerência de Tecnologia da Informação  
**De:** Equipe de Engenharia de Banco de Dados e Sistemas  
**Assunto:** Diagnóstico Integral dos 13 Incidentes Operacionais e Plano de Correção Priorizado  
**Data:** 24 de Novembro de 2026  
**Status:** Concluído e Validado em Ambiente de Homologação  

---

## 1. Sumário Executivo

A gestão da indústria contratou nossa equipe para conduzir uma investigação aprofundada sobre **13 relatos operacionais críticos** envolvendo o sistema legado de controle de peças, movimentações de estoque, custos e ordens de serviço (baseado em PostgreSQL 18 e aplicação Python).

A investigação confirmou que os problemas reportados não decorrem de instabilidades esporádicas de infraestrutura, mas sim de uma combinação de **fragilidades conceituais no esquema do banco de dados**, **quebra de princípios transacionais básicos (ACID)**, **concessão excessiva de privilégios de segurança** e **erros metodológicos em consultas analíticas em SQL**.

Todos os 13 incidentes foram diagnosticados com rigor técnico, reproduzidos experimentalmente em ambiente de homologação e contam com planos de correção definitivos e métodos objetivos de validação.

---

## 2. Visão Geral dos Principais Achados

As causas raízes dos incidentes foram agrupadas em quatro eixos estruturais:

```
┌───────────────────────────────────────────────────────────────────────────────────┐
│                             DIAGNÓSTICO ESTRUTURAL                                │
├─────────────────────────┬─────────────────────────┬───────────────────────────────┤
│ 1. Transações & ACID    │ 2. Modelo de Dados      │ 3. Consultas & Relatórios     │
│  • INC-002 (Race Cond.) │  • INC-005 (3FN Cache)  │  • INC-001 (Scan sem índice)  │
│  • INC-004 (Atomicidade)│  • INC-006 (Falta CHECK)│  • INC-003 (Fan-out / Custo)  │
│  • INC-012 (Conn. Leak) │  • INC-009 (Unicidade)  │  • INC-010 (Preço histórico)  │
│                         │  • INC-011 (Auditoria)  │  • INC-013 (Left Join / Where)│
│                         │                         │  • INC-014 (Granularidade AVG)│
├─────────────────────────┴─────────────────────────┴───────────────────────────────┤
│ 4. Segurança & Privilégios: INC-007 (Violação do Princípio do Menor Privilégio)   │
└───────────────────────────────────────────────────────────────────────────────────┘
```

1. **Quebra de Integridade Transacional e Concorrência (INC-002, INC-004, INC-012):**
   - Retiradas simultâneas geravam saldo negativo porque o sistema realizava leitura desconectada sem bloqueio pessimista (`FOR UPDATE`) e com validação tardia na aplicação.
   - Encerramento de ordens ocorria em duas transações separadas; falhas na segunda etapa deixavam a OS como `ENCERRADA` sem gravar o serviço executado.
   - Consultas repetidas retêm conexões ociosas em memória até esgotar o pool do cliente ou do SGBD.

2. **Fragilidades no Esquema e Ausência de Regras Declarativas no SGBD (INC-005, INC-006, INC-009, INC-011):**
   - Inexistência de restrições `CHECK` em movimentações e estoques, permitindo lançamentos com quantidades negativas ou zero.
   - Violação da 3ª Forma Normal com dados de fornecedor duplicados e dessincronizados na ficha de componentes.
   - Inexistência de restrição `UNIQUE` em lotes de importação, permitindo duplicações cumulativas em estoques ao reenviar arquivos.
   - Ausência de triggers de auditoria para capturar transições de status em ordens de serviço.

3. **Inconsistências em Consultas SQL e Análise de Custos (INC-001, INC-003, INC-010, INC-013, INC-014):**
   - Consultas ao histórico varriam 500 mil a 2 milhões de linhas por falta de índice composto e filtragem tardia.
   - O cálculo do custo de ordens realizava produto cartesiano (`itens_ordem` $\times$ `servicos_ordem`), multiplicando valores artificialmente, além de buscar o preço corrente de catálogo em vez do preço congelado no momento da intervenção.
   - Reajustes de preços no cadastro de componentes alteravam retroativamente os custos de ordens encerradas no passado.
   - Relatórios mensais ocultavam ordens legítimas por posicionar filtros de período no `WHERE` em vez do `ON` de `LEFT JOIN`.
   - Painéis setoriais distorciam a média de tempo de atendimento ao agregar na mesma query itens consumidos e ordens.

4. **Superconcessão de Privilégios (INC-007):**
   - A conta `pbl_app` detém `CREATE ON SCHEMA` e `ALL PRIVILEGES`, permitindo a execução de comandos DDL (`DROP TABLE`) e DML destrutivos (`TRUNCATE`), expondo o parque fabril a riscos graves de parada operacional.

---

## 3. Impacto para a Operação Industrial

| Área de Impacto | Severidade | Consequências Práticas Observadas |
|:---|:---:|:---|
| **Financeiro & Controladoria** | **Crítica** | Apurações de custos distorcidas em ordens de serviço (relatórios apresentando até o dobro do valor real); custos de ordens antigas sofrendo alteração indevida quando o preço de catálogo de uma peça é atualizado. |
| **Almoxarifado & Estoque** | **Crítica** | Estoques físicos e contábeis divergentes; saldos caindo para valores negativos devido a retiradas concorrentes desprotegidas; duplicação maciça de estoques e movimentações em caso de reenvio acidental de planilhas CSV. |
| **Planejamento de Manutenção** | **Alta** | Ordens encerradas constando sem os serviços executados por falhas transacionais; desaparecimento de ordens abertas em relatórios mensais; distorção dos tempos médios de atendimento dos setores industriais. |
| **TI & Infraestrutura** | **Alta** | Queda da aplicação por esgotamento de conexões abertas (`connection leak`); risco iminente de perda irreversível de dados históricos por permissões irrestritas (`TRUNCATE` concedido à aplicação). |

---

## 4. Limitações Relevantes da Investigação

- **Ambiente de Testes:** A investigação utilizou uma réplica exata da base de homologação (`pbl_industria_testes`), contendo 500.000 movimentações iniciais, expandida experimentalmente até 2.000.000 de registros para testes de escala.
- **Concorrência e Cargas:** As corridas de concorrência e vazamentos de recursos foram simulados via rotinas multithreading em ambiente local.
- **Migração em Produção:** As alterações DDL (adição de índices, constraints `CHECK` e `UNIQUE`) exigirão saneamento prévio dos registros históricos corrompidos já existentes antes de sua aplicação definitiva.

---

## 5. Plano de Correção Priorizado

O plano foi estruturado em quatro ondas sequenciais, balanceando **mitigação imediata de risco**, **integridade contábil** e **baixo impacto operacional**:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                        CRONOGRAMA DE IMPLANTAÇÃO RECOMENDADO                           │
├─────────────────┬───────────────────┬───────────────────┬──────────────────────────────┤
│ Onda 1: P0      │ Onda 2: P1        │ Onda 3: P2        │ Onda 4: P3                   │
│ Imediato (48h)  │ Semana 1          │ Semana 2          │ Mês 1                        │
├─────────────────┼───────────────────┼───────────────────┼──────────────────────────────┤
│ • INC-002       │ • INC-006         │ • INC-003         │ • INC-001                    │
│ • INC-004       │ • INC-009         │ • INC-010         │ • INC-005                    │
│ • INC-007       │ • INC-011         │ • INC-013         │ • INC-012                    │
│                 │                   │ • INC-014         │                              │
└─────────────────┴───────────────────┴───────────────────┴──────────────────────────────┘
```

### Detalhamento das Ações do Plano

| ID Ação | Relatos Atendidos | Mudança Proposta e Justificativa | Prioridade | Como Verificar o Funcionamento |
|:---:|:---:|:---|:---:|:---|
| **A-01** | **INC-002** | **Bloqueio pessimista e validação atômica no estoque.** Implementar `SELECT ... FOR UPDATE` na consulta de saldo e constraint `CHECK (quantidade >= 0)` em `industria.estoques`. Impede saldos negativos sob qualquer concorrência. | **P0 (Crítica)** | Disparar requisições simultâneas concorrentes com saldo insuficiente: a primeira é autorizada e a segunda é rejeitada, com saldo preservado $\ge 0$. |
| **A-02** | **INC-004** | **Unificação do encerramento da OS em transação atômica única.** Consolidar o `UPDATE ordens_servico` e o `INSERT servicos_ordem` em um único bloco `with conectar() as conn:`. Garante rollback integral em caso de falhas. | **P0 (Crítica)** | Simular erro de indisponibilidade no encerramento: a OS deve permanecer no status anterior (`EM_EXECUCAO`), sem inconsistência residual. |
| **A-03** | **INC-007** | **Aplicação do Princípio do Menor Privilégio.** Revogar `CREATE ON SCHEMA` e `ALL PRIVILEGES` do usuário `pbl_app`, concedendo apenas permissões granulares (`SELECT, INSERT, UPDATE`) e revogando `DELETE/TRUNCATE` em tabelas de histórico e auditoria. | **P0 (Crítica)** | Testar todas as opções legítimas da aplicação e confirmar bloqueio imediato (`permission denied`) para comandos de `TRUNCATE` ou DDL. |
| **A-04** | **INC-006** | **Saneamento e constraints declarativas de validação.** Aplicar DDL com `CHECK (quantidade > 0)` e `CHECK (tipo IN ('ENTRADA', 'SAIDA'))` em `movimentacoes`, após saneamento prévio de linhas históricas inconsistentes. | **P1 (Alta)** | Tentar inserir movimentação direta com quantidade zero ou negativa: o SGBD deve abortar com `CheckViolation`. |
| **A-05** | **INC-009** | **Idempotência no processamento de lotes externos.** Adicionar constraint `UNIQUE (chave_lote)` em `industria.importacoes` e checagem prévia na aplicação. Impede duplicação acidental de estoque por reenvio. | **P1 (Alta)** | Reenviar o mesmo arquivo CSV com o mesmo identificador de lote: o sistema deve acusar lote já processado sem alterar saldos. |
| **A-06** | **INC-011** | **Automação da trilha de auditoria para status de OS.** Criar trigger no PostgreSQL (`trg_auditoria_ordens_servico_status`) que intercepta alterações no status da OS e grava status anterior, novo, data e usuário na tabela `auditoria`. | **P1 (Alta)** | Alterar o status de uma OS via aplicação ou SQL e consultar a tabela `auditoria`: deve constar o log detalhado do evento. |
| **A-07** | **INC-003**<br>**INC-010** | **Reestruturação da consulta de custos via CTE e snapshot.** Substituir o cálculo em `consultar_custo_os` por CTEs segregadas (peças e serviços calculados separadamente) e utilizar `i.valor_unitario_aplicado` em vez do catálogo dinâmico. | **P2 (Média)** | Conferir o valor da OS-2026-001 (deve bater centavo a centavo com o financeiro) e reajustar preço de peça no catálogo confirmando que OS encerrada não muda. |
| **A-08** | **INC-013** | **Correção de predicados em junções externas (LEFT JOIN).** Transferir os filtros temporais de execução de serviços para a cláusula `ON` no relatório mensal, mantendo no `WHERE` apenas as datas de abertura da OS. | **P2 (Média)** | Emitir relatórios de fevereiro e outubro/2026: todas as ordens abertas devem ser listadas, exibindo 0 serviços para as que não tiveram execução no mês. |
| **A-09** | **INC-014** | **Segregação de granularidade no painel setorial.** Pré-agregar a quantidade de peças por OS em CTE antes de computar o tempo médio no agrupamento por setor, atribuindo peso 1 a cada OS encerrada. | **P2 (Média)** | Inserir peças em OS já encerrada de um setor e recalcular o painel: o total de peças aumenta, mas a média de tempo permanece rigorosamente estável. |
| **A-10** | **INC-001** | **Criação de índice composto e reestruturação do histórico.** Criar índice composto `(componente_id, momento DESC, id DESC)` em `movimentacoes` e antecipar filtro e LIMIT na consulta SQL. Ganho de performance superior a 99,9%. | **P3 (Melhoria)** | Medir o tempo de execução da consulta para períodos longos em base de 2 milhões de registros: a mediana deve cair de ~545 ms para menos de 1 ms. |
| **A-11** | **INC-005** | **Sincronização cadastral ou normalização da ficha de peças.** Implantar trigger de sincronização automática entre `fornecedores` e `componentes` (curto prazo) ou eliminar colunas de cache redundantes (longo prazo). | **P3 (Melhoria)** | Atualizar o telefone de um fornecedor e consultar a ficha de componentes vinculados: as informações devem coincidir instantaneamente. |
| **A-12** | **INC-012** | **Eliminação de vazamento de conexões no cliente.** Refatorar `consultar_indicador_repetidamente` para gerenciar sessões com blocos `with conectar() as conn:`, garantindo fechamento imediato. | **P3 (Melhoria)** | Disparar 20 consultas consecutivas: todas devem ser concluídas com êxito e zero sessões ociosas em `pg_stat_activity`. |

---

## 6. Conclusão e Próximos Passos

A investigação atesta que **todos os 13 incidentes foram satisfatoriamente explicados, comprovados por evidências técnicas e possuem soluções viáveis de baixo custo de implementação**. 

Recomendamos a imediata aprovação da **Onda 1 (Ações A-01, A-02 e A-03)** para blindar a integridade financeira e a segurança dos dados nas próximas 48 horas, seguida pelo cronograma planejado das demais fases.

Os detalhes técnicos completos, planos de execução, trechos de código e evidências de cada incidente estão disponíveis no **Anexo Técnico** que acompanha este documento.
