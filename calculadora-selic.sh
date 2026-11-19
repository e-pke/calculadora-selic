#!/usr/bin/env bash
# https://github.com/e-pke/
#
# Calculadora de rendimento acumulado da taxa SELIC.
# Consulta a série SGS 11 do Banco Central e gera fatores
# acumulados para cada mês entre as datas informadas.
#
# Dependências: bash, python3, requests, date (GNU), tput.

# Sequências ANSI utilizadas na formatação da interface.
# BLD/RST controlam o negrito; as demais variáveis definem
# cores do texto e do plano de fundo.
BLD="\033[1m"
RST="\033[0m"
RED="\033[1;31;49m"
R_BG="\033[1;37;41m"
GRE="\033[1;32;49m"
G_BG="\033[1;37;42m"
BLU="\033[1;34;49m"
B_BG="\033[1;37;44m"

# Stop and clear funcion
encerrar() {
	echo -e "\n${R_BG}   ENCERRADO                   ${RED}\uE0B0${RST}  "
	rm -r tmp_selic_* 2>/dev/null

	if [[ "$TELA_ALTERNATIVA" == 1 ]]; then
        echo
        read -r -p "   Pressione ENTER para retornar ao terminal..."
        tput rmcup
    fi
}
trap encerrar EXIT

# Utiliza o buffer alternativo do terminal para preservar
# o conteúdo anterior, semelhante ao comportamento do vim.
#
# smcup : entra na tela alternativa
# rmcup : retorna à tela original
# clear : limpa somente a tela ativa
# cup   : posiciona o cursor (linha, coluna)
#
# TELA_ALTERNATIVA indica se a operação foi bem-sucedida.

TELA_ALTERNATIVA=0

if [[ -t 1 ]] && command -v tput &>/dev/null; then
    if tput smcup 2>/dev/null; then
        TELA_ALTERNATIVA=1
        tput clear
        tput cup 0 0
    fi
fi

header() {
	echo -e "\n${BLD}"
	cat <<- EOF
	  ┌────────────────────────────────┐
	  │    RENDIMENTO DA TAXA SELIC    │
	  └────────────────────────────────┘
	                            by Єpke
EOF
	echo -en "\n${RST}"
	cat <<- EOF
	  Este script busca e mostra valores acumulados
	  da taxa selic para dado intervalo de datas.
	
	  A data inicial deve ser o primeiro dia do
	  primeiro mês a ser consultado e a data final,
	  o último dia do último mês consultado.
	  
	  Com o exemplo de datas, a inicial = 2023-01-01
	  e a final = 2023-03-31, o resultado será a taxa
	  selic acumulada dos seguintes períodos: 

	    01/01/2023 -> 31/03/2023
	    01/02/2023 -> 31/03/2023
	    01/03/2023 -> 31/03/2023
EOF
}

# Executa a calculadora Python sem depender de um arquivo .py.
#
# "$@" repassa os argumentos recebidos pela função Bash.
# O "-" instrui o Python a ler o código da entrada padrão.
# O delimitador 'PYTHON' impede a expansão de variáveis Bash
# dentro do código Python (Heredoc).
calculadora_bcb() {
    python3 - "$@" <<'PYTHON'
import argparse
import datetime as dt
import time
from decimal import Decimal, getcontext

import requests

# Mais precisão do que o necessário (bom para produto de muitos dias)
getcontext().prec = 50

BCB_SGS_SERIE_SELIC_DIARIA = 11
BCB_URL = "https://api.bcb.gov.br/dados/serie/bcdata.sgs.{serie}/dados"

def parse_date_br(s: str) -> dt.date:
    """Converte DD/MM/AAAA para date e valida o formato."""
    try:
        return dt.datetime.strptime(s, "%d/%m/%Y").date()
    except ValueError as e:
        raise SystemExit(f"Data inválida: {s!r}. Use DD/MM/AAAA.") from e

def to_decimal_ptbr(x: str) -> Decimal:
    """Converte valores numéricos da API para Decimal."""
    return Decimal(x.replace(",", "."))

def fmt_decimal_ptbr(x, casas: int = 8) -> str:
    """Formata um Decimal com vírgula e precisão definida."""
    return f"{x:.{casas}f}".replace(".", ",")

def fetch_sgs_series(serie: int, data_inicial: dt.date, data_final: dt.date) -> list[dict]:
    """
    Consulta dados históricos da série SGS no Banco Central.

    Realiza até 5 tentativas em caso de falha HTTP,
    utilizando intervalos progressivos entre tentativas.
    Retorna uma lista de registros com data e valor.
    """
    url = BCB_URL.format(serie=serie)
    params = {
        "formato": "json",
        "dataInicial": data_inicial.strftime("%d/%m/%Y"),
        "dataFinal": data_final.strftime("%d/%m/%Y"),
    }

    max_tentativas = 5
    ultima_excecao = None

    for tentativa in range(1, max_tentativas + 1):
        try:
            r = requests.get(url, params=params, timeout=30)
            r.raise_for_status()

            data = r.json()
            if not isinstance(data, list):
                raise SystemExit("Resposta inesperada da API do BCB (não retornou lista JSON).")

            return data

        except requests.exceptions.RequestException as e:
            ultima_excecao = e

            if tentativa < max_tentativas:
                time.sleep(tentativa * 2)
            else:
                raise SystemExit(
                    f"Falha ao consultar API do BCB após {max_tentativas} tentativas.\n"
                    f"Período: {data_inicial:%d/%m/%Y} até {data_final:%d/%m/%Y}\n"
                    f"Último erro: {ultima_excecao}"
                ) from e

def fator_acumulado_selic(dados: list[dict]) -> Decimal:
    """
    Calcula o fator acumulado por capitalização composta.

    Fórmula: produto(1 + taxa_diaria / 100)

    Retorna o fator multiplicativo, não o percentual.
    Exemplo: 1,12500000 representa rendimento de 12,5%.
    """
    fator = Decimal("1")
    for item in dados:
        v = to_decimal_ptbr(item["valor"])  # % ao dia
        fator *= (Decimal("1") + v / Decimal("100"))
    return fator

def main() -> None:
    ap = argparse.ArgumentParser(
        description="Calcula Selic acumulada (fator e %) via API SGS do BCB (série 11)."
    )
    ap.add_argument("data_inicial", help="DD/MM/AAAA")
    ap.add_argument("data_final", help="DD/MM/AAAA")
    ap.add_argument(
        "--inclusive",
        action="store_true",
        help="Trata data final como inclusiva (padrão: exclusiva, isto é, até o dia anterior).",
    )
    ap.add_argument(
        "--serie",
        type=int,
        default=BCB_SGS_SERIE_SELIC_DIARIA,
        help="Número da série SGS (padrão: 11 = Selic diária % a.d.).",
    )

    args = ap.parse_args()
    di = parse_date_br(args.data_inicial)
    df = parse_date_br(args.data_final)

    if df <= di:
        raise SystemExit("data_final deve ser maior que data_inicial.")

    # A data final é EXCLUSIVA por padrão.
    # Exemplo: 01/01/2023 a 01/04/2023 considera dados
    # até 31/03/2023. A opção --inclusive altera essa regra.
    df_consulta = df if args.inclusive else (df - dt.timedelta(days=1))

    if df_consulta < di:
        raise SystemExit("Intervalo vazio após aplicar data final exclusiva.")

    dados = fetch_sgs_series(args.serie, di, df_consulta)

    if not dados:
        raise SystemExit("A API retornou 0 pontos para o período informado.")

    fator = fator_acumulado_selic(dados)
    taxa_percent = (fator - Decimal("1")) * Decimal("100")

    print(fmt_decimal_ptbr(fator, 8))

if __name__ == "__main__":
    main()
PYTHON
}

# Fluxo principal: recebe as datas, calcula os fatores
# acumulados e gera um arquivo com os resultados.
main() {
	# Reinicializa os arquivos de saída para evitar que
    # execuções anteriores sejam concatenadas aos resultados.
	: > tmp_selic_COLUNA.txt
	: > tmp_selic_PRONTO.txt

	# Entrada de dados.
	# read -e habilita edição com Readline (Backspace, setas).
	# read -r preserva barras invertidas como caracteres literais.
	echo -ne "\n${B_BG}   DIGITE A DATA INICIAL:      ${BLU}\uE0B0${RST}  "
	read -e -r inicio
	echo -ne "\n${B_BG}   DIGITE A DATA FINAL:        ${BLU}\uE0B0${RST}  "
	read -e -r fim

	echo -e "\n${BLD}   PROCESSAMENTO\n   ────────────────────────"

	# Gera uma sequência mensal usando o dia 1 de cada mês.
	# O formato ISO (AAAA-MM-DD) permite comparar datas
	# cronologicamente como strings no Bash.
	echo -e "${RST}   [>] Gerando lista de datas "

	while [[ "$inicio" < "$fim" || "$inicio" == "$fim" ]]; do
    	date -d "$inicio" +"%d/%m/%Y"
    	inicio=$(date -d "$inicio +1 month" +"%Y-%m-%d")
	done > tmp_selic_DATAS.txt

	# Converte a data final para o formato esperado pela API.
	final=$(date -d "$fim" +"%d/%m/%Y")

	# Calcula o fator acumulado para cada data inicial.
	# Todos os cálculos compartilham a mesma data final.
	# tee exibe os resultados e os grava simultaneamente.
	echo -e "${RST}   [>] Buscando valores na calculadora "

	for inicial in $(cat tmp_selic_DATAS.txt | grep -v "#"); do
		echo -n "       $inicial = "
		calculadora_bcb "$inicial" "$final" --inclusive | tee -a tmp_selic_COLUNA.txt
	done

	# Transpõe os resultados de uma coluna para uma única
	# linha, separando os fatores por tabulações.
	echo -e "${RST}   [>] Transpondo em linha única "

	for taxa in $(cat tmp_selic_COLUNA.txt); do
		echo -en "$taxa\t" >> tmp_selic_PRONTO.txt
	done

	# Apresenta o arquivo gerado e tenta abri-lo.
	echo -e "\n${BLD}   SALVAMENTO\n   ────────────────────────"

	echo -e "${RST}   [>] Resultado salvo em:  ${BLD}tmp_selic_PRONTO.txt${RST}"

	echo -e "${RST}   [>] Abrindo arquivo"

	open tmp_selic_PRONTO.txt
}

header

while true; do
    main

    echo -ne "\n${G_BG}   EXECUTAR NOVAMENTE? [y/N]   ${GRE}\uE0B0${RST}  "
    read -r -e resposta

    [[ "$resposta" == "y" ]] || break
done
