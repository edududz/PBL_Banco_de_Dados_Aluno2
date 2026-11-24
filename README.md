# PBL Banco de Dados | Investigação de um Sistema Legado

Repositório dedicado à investigação técnica, diagnóstico e plano de correção de um sistema industrial legado baseado em **PostgreSQL 18** e **Python**, referente ao **PBL de Banco de Dados (2026/2)**.

A gestão da indústria contratou a equipe para investigar **13 relatos operacionais críticos** reunidos pelas equipes de almoxarifado, manutenção, financeiro e TI, formulando hipóteses, examinando artefatos, comprovando causas raízes e propondo soluções justificadas.

---

## 📑 Documentos Principais da Entrega

| Documento | Descrição |
|:---|:---|
| 📊 **[RELATORIO_EXECUTIVO.md](RELATORIO_EXECUTIVO.md)** | Relatório executivo formal direcionado à diretoria e gestão da indústria, com resumo dos achados, impactos operacionais, matriz de priorização e plano de correção em 4 ondas. |
| 📋 **[ANEXO_TECNICO.md](ANEXO_TECNICO.md)** | Caderno técnico compilando as 13 fichas de incidentes com Hipóteses, Procedimentos reproduzíveis, Evidências numéricas e de código, Conclusões e Soluções com Validação. |

---

## 🔍 Mapa dos 13 Incidentes Investigados

Todos os incidentes contam com cadernos Jupyter interativos documentados, com scripts reproduzíveis e fichas técnicas individuais:

| ID | Incidente Relatado | Causa Raiz Diagnosticada | Caderno de Investigação |
|:---:|:---|:---|:---:|
| **INC-001** | Histórico de movimentações lento em grandes períodos | Ausência de índice composto e varredura sequencial (`Parallel Seq Scan`) com LIMIT tardio | [`notebooks/INC-001.ipynb`](notebooks/INC-001.ipynb) |
| **INC-002** | Duas retiradas aprovadas para um saldo insuficiente | Condição de corrida (Race Condition / TOCTOU), falta de `FOR UPDATE` e ausência de constraint `CHECK` | [`notebooks/INC-002.ipynb`](notebooks/INC-002.ipynb) |
| **INC-003** | Custo da OS diverge da apuração financeira | Produto cartesiano (fan-out join $M \times N$) e uso de preço de catálogo corrente em vez de histórico | [`notebooks/INC-003.ipynb`](notebooks/INC-003.ipynb) |
| **INC-004** | Erro ao encerrar OS deixa ordem encerrada sem o serviço | Quebra de atomicidade transacional (dois blocos de conexão separados sem rollback unificado) | [`notebooks/INC-004.ipynb`](notebooks/INC-004.ipynb) |
| **INC-005** | Dados de fornecedor divergem entre consultas | Violação da 3ª Forma Normal (colunas de cache em `componentes`) gerando anomalia de atualização | [`notebooks/INC-005.ipynb`](notebooks/INC-005.ipynb) |
| **INC-006** | Movimentações com quantidades inválidas ($\le 0$) | Falta de restrições de validação declarativa (`CHECK constraints`) a nível de SGBD | [`notebooks/INC-006.ipynb`](notebooks/INC-006.ipynb) |
| **INC-007** | Permissões excessivas da conta `pbl_app` | Violação do Princípio do Menor Privilégio (`CREATE ON SCHEMA` e `ALL PRIVILEGES` concedidos) | [`notebooks/INC-007.ipynb`](notebooks/INC-007.ipynb) |
| **INC-009** | Reenvio de arquivo gera lançamentos repetidos | Falta de idempotência e ausência de restrição `UNIQUE (chave_lote)` na tabela de importações | [`notebooks/INC-009.ipynb`](notebooks/INC-009.ipynb) |
| **INC-010** | Custo de ordem encerrada mudou após reajuste | Consulta apontando para `c.preco_atual` dinâmico em vez de congelar `i.valor_unitario_aplicado` | [`notebooks/INC-010.ipynb`](notebooks/INC-010.ipynb) |
| **INC-011** | Mudança de status da OS sem registro | Inexistência de trigger de auditoria no SGBD para capturar transições na tabela `ordens_servico` | [`notebooks/INC-011.ipynb`](notebooks/INC-011.ipynb) |
| **INC-012** | Falha após consultas repetidas do indicador | Vazamento de conexões (*connection leak*) por instâncias retidas sem `close()` na memória | [`notebooks/INC-012.ipynb`](notebooks/INC-012.ipynb) |
| **INC-013** | Ordens somem do relatório mensal | Filtro de período de serviços posicionado na cláusula `WHERE`, anulando o `LEFT JOIN` | [`notebooks/INC-013.ipynb`](notebooks/INC-013.ipynb) |
| **INC-014** | Registrar peças altera o tempo médio de atendimento | Mistura de granularidades (ordens x itens) duplicando linhas na junção e enviesando o `AVG()` | [`notebooks/INC-014.ipynb`](notebooks/INC-014.ipynb) |

---

## 📁 Estrutura do Repositório

```text
PBL_Banco_de_Dados_Aluno/
│
├── aplicacao/                      # Código da aplicação Python legada
│   ├── app.py                      # CLI interativa do sistema
│   ├── database.py                 # Funções de conexão com o PostgreSQL
│   ├── importacao.py               # Rotina de importação de arquivos CSV
│   ├── operacoes.py                # Regras de movimentação, OS e estoques
│   ├── relatorios.py               # Consultas analíticas e relatórios de custos
│   ├── uso_repetido.py             # Módulo com a rotina de consultas repetidas
│   └── requirements.txt            # Dependências do projeto (psycopg, python-dotenv)
│
├── configuracao/                   # Scripts de provisionamento
│   ├── 00_configurar_acesso.sql    # Concessão original de acessos do pbl_app
│   └── restaurar_pbl.ps1           # Script PowerShell para restauração do dump
│
├── dados/                          # Dados de trabalho e arquivos de carga
│   ├── importacao_exemplo.csv      # CSV fornecido para testes de importação
│   └── backups/                    # Dumps de segurança da base de testes
│
├── docker/                         # Configuração de contêineres
│   └── compose.yaml                # Definição do serviço PostgreSQL 18
│
├── evidencias/                     # Evidências geradas durante os experimentos
│   ├── INC-001/                    # Planos EXPLAIN, medições e comparações
│   ├── instalacao/                 # Validações de contagem inicial da base
│   └── mapeamento/                 # Diagramas e metadados das tabelas
│
├── notebooks/                      # Cadernos Jupyter de investigação
│   ├── 00_validacao_ambiente.ipynb # Validação inicial de tabelas e contagens
│   ├── 01_mapeamento_banco.ipynb   # Mapeamento relacional de schemas, PKs e FKs
│   ├── INC-001.ipynb               # Investigação do desempenho de histórico
│   ├── INC-002.ipynb               # Investigação de retiradas simultâneas (concorrência)
│   ├── INC-003.ipynb               # Investigação da divergência de custos na OS-2026-001
│   ├── INC-004.ipynb               # Investigação de falha atômica no encerramento de OS
│   ├── INC-005.ipynb               # Investigação de dados divergentes de fornecedores
│   ├── INC-006.ipynb               # Investigação de quantidades inválidas e restrições
│   ├── INC-007.ipynb               # Auditoria de permissões da conta da aplicação
│   ├── INC-009.ipynb               # Investigação de reenvio de lotes e duplicações
│   ├── INC-010.ipynb               # Investigação de mutabilidade de custo em OS encerrada
│   ├── INC-011.ipynb               # Investigação de transição de status sem auditoria
│   ├── INC-012.ipynb               # Investigação de esgotamento de conexões (leak)
│   ├── INC-013.ipynb               # Investigação de ordens ausentes em relatório mensal
│   └── INC-014.ipynb               # Investigação de distorção no cálculo do tempo médio
│
├── tutorial/                       # Manuais e guias didáticos do PBL
│   ├── GUIA_Estudante_PBL_PostgreSQL.md
│   └── GUIA_Estudante_PBL_PostgreSQL.pdf
│
├── ANEXO_TECNICO.md                # Compilação completa das 13 Fichas Técnicas
├── RELATORIO_EXECUTIVO.md          # Relatório executivo e matriz de priorização
├── industria_homologacao_500k.dump # Dump oficial com 500 mil movimentações
└── README.md                       # Documentação principal do repositório
```

---

## 🚀 Como Reproduzir o Ambiente

### 1. Pré-requisitos
- **Windows 10/11** ou **Linux/macOS**
- **Python 3.11+**
- **PostgreSQL 18** (via Docker Compose ou instalação nativa)

### 2. Preparação do Banco de Dados
Na pasta `docker/`:
```bash
docker compose up -d --wait
```

Restauração da base de referência utilizando o script PowerShell:
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\configuracao\restaurar_pbl.ps1 -Modo Docker -ComposeFile .\docker\compose.yaml
```

### 3. Configuração do Ambiente Virtual Python
Na raiz do repositório:
```bash
python -m venv .venv
.\.venv\Scripts\pip install -r .\aplicacao\requirements.txt
```

Crie o arquivo `aplicacao/.env` baseado no `.env.example`:
```dotenv
PGHOST=127.0.0.1
PGPORT=55432
PGDATABASE=pbl_industria_homologacao
PGUSER=pbl_app
PGPASSWORD=sua_senha_local
```

### 4. Verificação Rápida da Aplicação
```bash
python aplicacao/app.py verificar
python aplicacao/app.py estoques
python aplicacao/app.py componentes
```
