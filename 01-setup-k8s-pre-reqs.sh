#!/usr/bin/env bash
# 01-setup-preprod.sh
# Kubernetes HA - Initial configurations (Pre-prod)
# Autor: Ing. Jesús A. Chávez Becerra

# Verificación temprana de requisitos
if ! command -v bash &>/dev/null; then
    echo "ERROR: bash no está instalado o no está en el PATH" >&2
    exit 1
fi

# =====================
# Inicialización
# =====================
K8S_BASE_DIR="/root/k8s-installer"
K8S_VARIABLES="${K8S_BASE_DIR}/cluster.env"
K8S_INVENTORY="${K8S_BASE_DIR}/inventory.csv"
K8S_CACHE_DIR="${K8S_BASE_DIR}/state"
YAML_BASE_PATH="${K8S_BASE_DIR}/yamls"

failed_list=()
PENDING_REBOOT=0
passed_checks=0
failed_checks=0
total_checks=0

# =====================
# Colores ANSI
# =====================
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
MAGENTA='\033[1;35m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Modo terminal seguro (útil en multiexec / ejecución no interactiva)
INTERACTIVE_TTY=false
if [[ -t 0 && -t 1 ]]; then
    INTERACTIVE_TTY=true
fi

if [[ "$INTERACTIVE_TTY" != true || -n "${K8S_NO_COLOR:-}" ]]; then
    RED=''
    GREEN=''
    CYAN=''
    MAGENTA=''
    YELLOW=''
    NC=''
fi

safe_clear() {
    if [[ "$INTERACTIVE_TTY" == true && -n "${TERM:-}" ]]; then
        clear || true
    fi
}

pause_prompt() {
    local message="$1"
    if [[ "$INTERACTIVE_TTY" == true ]]; then
        read -r -p "$message" _
    else
        echo -e "${YELLOW}[INFO]${NC} Prompt omitido (sin TTY): ${message}"
    fi
}

read_with_default() {
    local __var_name="$1"
    local __prompt="$2"
    local __default="${3:-}"
    local __value=""

    if [[ "$INTERACTIVE_TTY" == true ]]; then
        read -r -p "$__prompt" __value || true
        if [[ -z "$__value" && -n "$__default" ]]; then
            __value="$__default"
        fi
    else
        __value="$__default"
        if [[ -z "$__value" ]]; then
            echo -e "${RED}[ERROR]${NC} Se requiere entrada interactiva y no hay TTY para: $__prompt"
            return 1
        fi
        echo -e "${YELLOW}[INFO]${NC} Sin TTY, usando valor por defecto '${__value}' para: $__prompt"
    fi

    printf -v "$__var_name" '%s' "$__value"
}

# =====================
# Sistema de Caché (Estado)
# =====================
mkdir -p "${K8S_CACHE_DIR}"

# Función para verificar caché
function check_cache() {
    local check_name="$1"
    if [[ -f "${K8S_CACHE_DIR}/${check_name}.ok" ]]; then
        echo -e "${GREEN}[SKIP]${NC} Validación previa encontrada para '${check_name}'"
        ((passed_checks++))
        ((total_checks++))
        return 0
    fi
    return 1
}

# Función para marcar éxito
function mark_success() {
    local check_name="$1"
    touch "${K8S_CACHE_DIR}/${check_name}.ok"
}

# =====================
# Funciones de Log
# =====================
function log() {
    echo -e "${MAGENTA}[LOG]${NC} $1"
}

function check() {
    _log_message "${CYAN}" "CHECK" "${GREEN}OK: $passed_checks${NC}, ${RED}ERROR: $failed_checks${NC}"
}

# =====================
# Header y Componentes
# =====================
function show_header() {
    safe_clear
    local BOLD='\033[1m'
    local SEP=" ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬ "

    # Detección dinámica del SO
    local os_pretty os_name os_version
    if [[ -f /etc/os-release ]]; then
        os_name=$(    . /etc/os-release 2>/dev/null && echo "${NAME:-}")
        os_version=$( . /etc/os-release 2>/dev/null && echo "${VERSION_ID:-}")
        os_pretty=$(  . /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-}")
        [[ -z "$os_pretty" ]] && os_pretty="${os_name:-Desconocido}${os_version:+ $os_version}"
    else
        os_pretty="Linux (distro desconocida)"
    fi

    detect_role 2>/dev/null

    echo -e "${CYAN}${SEP}${NC}"
    echo -e "  ${BOLD}${MAGENTA}KUBERNETES HA ON-PREMISE | Infrastructure Compliance & Validation Tool${NC}"
    echo -e "${CYAN}${SEP}${NC}"
    echo
    echo -e "  ${BOLD}IDENTIFICACIÓN DEL NODO:${NC}"
    echo -e "  • ${CYAN}Host${NC}: $(hostname)      • ${CYAN}Rol${NC}: ${MAGENTA}${ROLE}${NC}        • ${CYAN}IP${NC}: ${ROLE_IP:-Detectando...}"
    echo -e "  • ${CYAN}OS${NC}  : ${os_pretty}      • ${CYAN}Arch${NC}: $(uname -m)      • ${CYAN}Ver${NC}: ${YELLOW}v1.5.0${NC}"
    echo
    echo -e "  ${BOLD}AUTORÍA Y DISEÑO:${NC}"
    echo -e "  • ${CYAN}Ing. Jesús A. Chávez Becerra${NC} | DevSecOps, Cloud and Infrastructure Architect"
    echo
    if [[ -d "${K8S_CACHE_DIR}" && "$(ls -A "${K8S_CACHE_DIR}" 2>/dev/null)" ]]; then
        echo -e "  ${BOLD}SITUACIÓN DE LA EJECUCIÓN:${NC}"
        echo -e "  » ${GREEN}Modo Rápido Activo${NC} (Caché detectada en ${K8S_CACHE_DIR})"
        echo
    fi

    show_components_to_validate
    echo -e "\n${CYAN}${SEP}${NC}"
    pause_prompt "  Presione [ENTER] para iniciar la auditoría de cumplimiento... "
    echo -e "\n"
}

function show_components_to_validate() {
    echo -e "  ${BOLD}ALCANCE DE LA VALIDACIÓN PARA ESTE NODO:${NC}"
    echo
    echo -e "  ${YELLOW}[ INFRAESTRUCTURA BASE ]${NC} ───────── (Común a todos los nodos)"
    echo -e "  • Red & Hostname        • Repositorios OS       • Seguridad (Firewall/SELinux)"
    echo -e "  • Recursos (Swap/Time)  • Kernel & Updates      • Conectividad Intra-Cluster"
    echo
    echo -e "  ${YELLOW}[ COMPONENTES DE ROL ]${NC} ─────────── (Específicos para ${MAGENTA}$ROLE${YELLOW})${NC}"

    case "$ROLE" in
        BALANCEADOR)
            echo -e "  » Repositorio HAProxy                   » Servicio HAProxy (Instalación/Config)"
            if [[ $(count_balancers) -gt 1 ]]; then
                echo -e "  » Keepalived (Alta Disponibilidad)      » Virtual IP (Cluster Entrypoint)"
            fi
            ;;
        MANAGER)
            echo -e "  » Container Runtime (containerd)        » Storage (local-path mount flags)"
            echo -e "  » Control Plane (kubeadm/kubectl)       » Cgroups v2 & Kubelet Service"
            echo -e "  » Networking (Calico Prereqs)           » Docker/K8s Repositories"
            ;;
        WORKER)
            echo -e "  » Container Runtime (containerd)        » Storage (local-path mount flags)"
            echo -e "  » Kubelet Service & Config              » Cgroups v2 Habilitado"
            echo -e "  » Networking (Calico Prereqs)           » Optimización WSS (WebSockets)"
            ;;
    esac
}

# =====================
# Función de detección de Sistema Operativo
# =====================
function detect_os() {
    if [[ -f /etc/oracle-release ]]; then
        OS="OracleLinux"
        OS_VERSION=$(grep -oP '(?<=release )[\d.]+' /etc/oracle-release | cut -d. -f1-2)
    elif [[ -f /etc/redhat-release ]]; then
        OS="RHEL"
        OS_VERSION=$(grep -oP '(?<=release )[\d.]+' /etc/redhat-release | cut -d. -f1-2)
    else
        echo -e "${RED}[ERROR]${NC} Sistema operativo no soportado"
        exit 1
    fi
    
    # Añadir detección de arquitectura
    ARCH=$(uname -m)
    echo -e "${CYAN}[INFO]${NC} Sistema Detectado: ${MAGENTA}${OS} ${OS_VERSION}${NC} (Arquitectura: ${ARCH})"

    if [[ "$ARCH" != "x86_64" ]]; then
        echo -e "${RED}[ERROR]${NC} Este script solo soporta arquitectura x86_64 (64 bits)"
        echo -e "${CYAN}[INFO]${NC} Arquitectura detectada: $ARCH"
        echo -e "${CYAN}[INFO]${NC} El script no es compatible con arquitecturas ARM (aarch64) u otras"
        exit 1
    fi
}

# =====================
# Funciones de Log de estado
# =====================
function _log_message() {
    local color="$1"
    local tag="$2"
    local msg="$3"
    echo -e "${color}[${tag}]${NC} ${msg}"
}

function log_success() {
    ((passed_checks++))
    [[ -n "$1" ]] && _log_message "${GREEN}" "OK" "$1"
}

function log_failure() {
    ((failed_checks++))
    local msg="${1:-Validación fallida}"
    # Guardamos en la lista aunque vayamos a salir, por si acaso
    failed_list+=("$msg")
    
    # Imprimimos el mensaje de error estándar
    _log_message "${RED}" "ERROR" "$msg"
    
    # --- PARADA DE EMERGENCIA ---
    echo -e "\n${RED}🛑 [BLOQUEO] El script se detendrá aquí.${NC}"
    echo -e "${YELLOW}Debes corregir este error antes de continuar con las siguientes validaciones.${NC}"
    exit 1
}

# =====================
# Validaciones Comunes
# =====================
function validate_inventory() {
    safe_clear
    echo -e "${YELLOW}--- Validación de existencia y formato de '${K8S_INVENTORY}' ---${NC}"
    log "Validando archivo de inventario..."

    # =========================================================
    # 1. CASO: ARCHIVO NO EXISTE -> ASISTENTE DE CREACIÓN
    # =========================================================
    if [[ ! -f "$K8S_INVENTORY" ]]; then
        echo -e "${RED}[ERROR]${NC} Archivo ${YELLOW}${K8S_INVENTORY}${NC} no encontrado."
        echo -e "${CYAN}[ASISTENTE]${NC} Generando configuración para ESTE servidor..."
        
        # A) Detectar Hostname
        local my_host=$(hostname)
        
        # B) Detectar IPs y manejar múltiples interfaces
        local my_ips_raw=$(hostname -I)
        local my_ips_array=($my_ips_raw)
        local selected_ip=""
        
        echo -e "\nHostname detectado: ${MAGENTA}${my_host}${NC}"
        
        if [[ ${#my_ips_array[@]} -eq 0 ]]; then
            echo -e "${RED}[ERROR]${NC} No se detectó ninguna IP. Verifica tu red."
            exit 1
        elif [[ ${#my_ips_array[@]} -eq 1 ]]; then
            selected_ip="${my_ips_array[0]}"
            echo -e "IP detectada      : ${MAGENTA}${selected_ip}${NC}"
        else
            echo -e "${YELLOW}[ATENCIÓN]${NC} Se detectaron múltiples IPs. ¿Cuál usarás para el cluster?"
            local i=1
            for ip in "${my_ips_array[@]}"; do
                echo -e "  [$i] ${MAGENTA}$ip${NC}"
                ((i++))
            done
            echo
            # Leemos de /dev/tty para asegurar interacción incluso dentro de scripts
            read_with_default ip_choice "Selecciona el número de la IP correcta (1-${#my_ips_array[@]}): " "1"
            
            if [[ "$ip_choice" =~ ^[0-9]+$ ]] && (( ip_choice >= 1 && ip_choice <= ${#my_ips_array[@]} )); then
                selected_ip="${my_ips_array[$((ip_choice-1))]}"
            else
                selected_ip="${my_ips_array[0]}"
                echo -e "${YELLOW}[WARN]${NC} Selección inválida. Usando la primera IP: $selected_ip"
            fi
        fi

        # C) Preguntar Rol
        echo
        echo "Selecciona el ROL de este servidor:"
        echo "  [1] MANAGER (Control Plane)"
        echo "  [2] WORKER  (Nodo de trabajo)"
        echo "  [3] BALANCEADOR (HAProxy)"
        read_with_default role_opt "Opción (1-3): " "1"
        
        local my_role="MANAGER" # Default
        case $role_opt in
            2) my_role="WORKER" ;;
            3) my_role="BALANCEADOR" ;;
        esac

        # NUEVO: Preguntar número de orden
        echo
        read_with_default my_order_role "Ingrese el número de ${my_role} (ej: 1, 2, 3...): " "1"
        # Validación simple para que no quede vacío
        if [[ -z "$my_order_role" ]]; then my_order_role="1"; fi

        # D) Generar el comando mágico
        echo
        echo -e "${GREEN}✅ Copia y ejecuta este comando para registrar este nodo:${NC}"
        echo "----------------------------------------------------------------"
        # CAMBIO: Se agrega ${my_order_role} como segundo campo
        echo -e "${CYAN}echo \"${my_role},${my_order_role},${my_host},${selected_ip}\" >> ${K8S_INVENTORY}${NC}"
        echo -e "----------------------------------------------------------------"
        echo -e "${CYAN}[NOTA]${NC} Cuando ${K8S_INVENTORY} tenga todos los servidores, vuelve a ejecutar este script."
        
        ((total_checks++))
        log_failure "Archivo ${K8S_INVENTORY} no encontrado"
    fi

    # =========================================================
    # 2. CASO: ARCHIVO EXISTE -> VALIDACIÓN RIGUROSA
    # =========================================================
    
    # Check si está vacío
    if [[ ! -s "$K8S_INVENTORY" ]]; then
        log_failure "Archivo vacío"
        echo -e "${RED}[ERROR]${NC} El archivo ${YELLOW}${K8S_INVENTORY}${NC} está vacío."
        ((total_checks++))
        exit 1
    fi

    # Limpieza automática (Auto-Healing de líneas vacías)
    local _tmp_clean
    _tmp_clean="$(mktemp)"
    grep -Ev '^[[:space:]]*$' "$K8S_INVENTORY" > "$_tmp_clean"

    if ! cmp -s "$K8S_INVENTORY" "$_tmp_clean"; then
        local _bkp="bkp_$(basename -- "$K8S_INVENTORY")_$(date +%s)"
        cp -f -- "$K8S_INVENTORY" "$(dirname -- "$K8S_INVENTORY")/$_bkp"
        mv -f -- "$_tmp_clean" "$K8S_INVENTORY"
        echo -e "${CYAN}[INFO]${NC} Se limpiaron líneas vacías. Backup: ${YELLOW}$_bkp${NC}"
    else
        rm -f -- "$_tmp_clean"
    fi

    # Validación línea por línea
    local valid_lines=0
    local line_num=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_num++))
        [[ "$line" =~ ^#.*$ ]] && continue # Ignorar comentarios

        # A) Espacios prohibidos
        if [[ "$line" =~ [[:space:]] ]]; then
            log_failure "Espacios detectados"
            echo -e "${RED}[ERROR]${NC} Línea $line_num: Contiene espacios (prohibido). -> '$line'"
            ((total_checks++)); exit 1
        fi

        # B) Caracteres prohibidos
        if [[ "$line" =~ [^A-Za-z0-9._\-,] ]]; then
            log_failure "Caracteres inválidos"
            echo -e "${RED}[ERROR]${NC} Línea $line_num: Caracteres inválidos. -> '$line'"
            echo " Permitido: Alfanuméricos, . - _ ,"
            ((total_checks++)); exit 1
        fi

        # C) Estructura CSV (4 campos ahora)
        IFS=',' read -r rol role_order hostname ip extra <<< "$line"
        if [[ -z "$rol" || -z "$role_order" || -z "$hostname" || -z "$ip" ]]; then
            log_failure "Campos incompletos"
            echo -e "${RED}[ERROR]${NC} Línea $line_num: Formato incorrecto. -> '$line'"
            echo " Esperado: ROL,ORDER,HOSTNAME,IP"
            ((total_checks++)); exit 1
        fi

        # D) Campos extra
        if [[ -n "$extra" ]]; then
            log_failure "Demasiados campos"
            echo -e "${RED}[ERROR]${NC} Línea $line_num: Sobran campos. -> '$line'"
            ((total_checks++)); exit 1
        fi

        ((valid_lines++))
    done < "$K8S_INVENTORY"

    echo -e "${CYAN}[INFO]${NC} Contenido validado:"
    echo "--------------------------------"
    cat "$K8S_INVENTORY"
    echo "--------------------------------"

    if [[ "$valid_lines" -eq 0 ]]; then
        log_failure "Sin servidores válidos"
        echo -e "${RED}[ERROR]${NC} El archivo no contiene líneas válidas."
        ((total_checks++)); exit 1
    fi

        # E) DUPLICADOS: Hostnames e IPs
    local dup_hostnames dup_ips
    dup_hostnames=$(grep -v '^#' "$K8S_INVENTORY" | cut -d',' -f3 | sort | uniq -d)
    dup_ips=$(grep -v '^#' "$K8S_INVENTORY" | cut -d',' -f4 | sort | uniq -d)

    if [[ -n "$dup_hostnames" || -n "$dup_ips" ]]; then
        log_failure "Duplicados en inventario"
        echo -e "${RED}[ERROR]${NC} Se detectaron valores duplicados en ${YELLOW}${K8S_INVENTORY}${NC}."
        if [[ -n "$dup_hostnames" ]]; then
            echo -e "${RED}  Hostnames duplicados:${NC}"
            echo "$dup_hostnames" | while read -r h; do
                echo -e "    - ${YELLOW}$h${NC}"
            done
        fi
        if [[ -n "$dup_ips" ]]; then
            echo -e "${RED}  IPs duplicadas:${NC}"
            echo "$dup_ips" | while read -r ip; do
                echo -e "    - ${YELLOW}$ip${NC}"
            done
        fi
        echo -e "${CYAN}[ACCIÓN]${NC} Corrige ${YELLOW}${K8S_INVENTORY}${NC} y vuelve a ejecutar el script."
        ((total_checks++)); exit 1
    fi

    log_success "Inventario ${YELLOW}${K8S_INVENTORY}${NC} validado ($valid_lines nodos)"
    ((total_checks++))
}

function validate_repos_commons() {
    # 1. Check Caché
    if check_cache "validate_repos_commons"; then return; fi

    echo -e "${YELLOW}--- Validación de repositorios comunes ---${NC}"
    log "Verificando repos BaseOS/AppStream/UEK..."

    # 0. Skip seguro si el host es cliente Spacewalk/Satellite
    if rpm -qa | grep -qi spacewalk; then
        echo -e "${GREEN}[SKIP]${NC} Cliente Spacewalk detectado (rpm -qa | grep spacewalk)."
        echo -e "${CYAN}[INFO]${NC} Se asume que los repos son gestionados externamente por Spacewalk."
        echo -e "${CYAN}[TIP]${NC} Si no usas Spacewalk, considera desregistrar el cliente para evitar lags en dnf."
        log_success "Spacewalk detectado - se omite validación detallada de repos comunes."
        mark_success "validate_repos_commons"
        ((total_checks++))
        return
    fi

    # 1. Verificación básica de archivos .repo
    if [[ -z $(find /etc/yum.repos.d/ -name "*.repo" -print -quit) ]]; then
        # Si no hay archivos, sugerimos crearlos antes de morir
        echo -e "${CYAN}[SOLUCIÓN]${NC} No tienes archivos en /etc/yum.repos.d/. Restaura los repositorios por defecto."
        log_failure "No se encontraron archivos .repo en /etc/yum.repos.d/"
        ((total_checks++))
        return
    fi

    local distro="GENERIC"
    if grep -qi "Oracle" /etc/os-release; then
        distro="Oracle Linux"
    elif grep -qi "Red Hat" /etc/os-release; then
        distro="RHEL"
    fi

    echo -e "${CYAN}[INFO]${NC} Analizando todos los repositorios (Habilitados y Deshabilitados)..."

    # --- OPTIMIZACIÓN CRÍTICA: LC_ALL=C para evitar errores por idioma español ---
    local dnf_output
    # Forzamos inglés para que el grep funcione siempre
    # EXTRA: --cacheonly para no salir a internet si el cliente está offline
    dnf_output=$(LC_ALL=C dnf repolist all -v --cacheonly 2>/dev/null | grep -E "^Repo-id|^Repo-baseurl|^Repo-status")

    declare -A REPO_URLS
    local disabled_repos=()
    local current_id=""
    local current_status=""

    # Parseo de la salida
    while IFS= read -r line; do
        if [[ "$line" =~ ^Repo-id[[:space:]]*:[[:space:]]*(.*) ]]; then
            current_id="${BASH_REMATCH[1]}"
            current_status=""
        elif [[ "$line" =~ ^Repo-status[[:space:]]*:[[:space:]]*(.*) ]]; then
            current_status="${BASH_REMATCH[1]}"
            if [[ "$current_status" == "disabled" ]]; then
                disabled_repos+=("$current_id")
            fi
        elif [[ "$line" =~ ^Repo-baseurl[[:space:]]*:[[:space:]]*(.*) ]]; then
            if [[ "$current_status" == "enabled" && -n "$current_id" ]]; then
                REPO_URLS["$current_id"]="${BASH_REMATCH[1]}"
            fi
        fi
    done <<< "$dnf_output"

    # =========================================================
    # CASO 1: NO SE DETECTARON REPOSITORIOS HABILITADOS
    # =========================================================
    if [[ ${#REPO_URLS[@]} -eq 0 ]]; then
        echo -e "\n${RED}[ERROR CRÍTICO]${NC} No tienes ningún repositorio habilitado."

        # Diagnóstico detallado antes de salir
        if [[ ${#disabled_repos[@]} -gt 0 ]]; then
            echo -e "${YELLOW}[DIAGNÓSTICO]${NC} Tienes ${#disabled_repos[@]} repositorios instalados pero están ${RED}DESHABILITADOS${NC}."
            echo -e "${CYAN}[LISTA PARCIAL]${NC} Algunos repositorios detectados:"
            for dr in "${disabled_repos[@]:0:5}"; do echo -e " - $dr"; done
            [[ ${#disabled_repos[@]} -gt 5 ]] && echo " - ... y otros $((${#disabled_repos[@]} - 5)) más."

            echo -e "\n${GREEN}[SOLUCIÓN]${NC} Ejecuta este comando para habilitar los esenciales:"
            if [[ "$distro" == "Oracle Linux" ]]; then
                echo -e "${MAGENTA}sudo dnf config-manager --set-enabled ol9_baseos_latest ol9_appstream${NC}"
            else
                echo -e "${MAGENTA}sudo dnf config-manager --set-enabled <nombre-del-repo>${NC}"
            fi
        else
            echo -e "${YELLOW}[DIAGNÓSTICO]${NC} El sistema parece vacío o 'dnf' no responde correctamente."
            echo -e "${GREEN}[SOLUCIÓN]${NC} Intenta reinstalar los repositorios base:"
            if [[ "$distro" == "Oracle Linux" ]]; then
                echo -e "${MAGENTA}sudo dnf config-manager --add-repo https://yum.oracle.com/repo/OracleLinux/OL9/baseos/latest/x86_64/${NC}"
            fi
        fi

        # Finalmente llamamos a log_failure que detendrá el script
        echo ""
        log_failure "No hay repositorios habilitados para instalar paquetes."
        ((total_checks++))
        return
    fi

    # =========================================================
    # CASO 2: TODO OK, LISTAMOS Y VALIDAMOS ESENCIALES
    # =========================================================
    echo -e "${CYAN}[INFO]${NC} Repositorios Habilitados detectados: ${#REPO_URLS[@]}"
    for id in "${!REPO_URLS[@]}"; do
        echo -e " - ${GREEN}${id}${NC}"
    done

    # Buscamos BaseOS, AppStream, UEK
    local missing_repos=()
    local baseos_found=0
    local appstream_found=0
    local uek_found=0

    for repo_id in "${!REPO_URLS[@]}"; do
        local url="${REPO_URLS[$repo_id]}"
        url="${url,,}"
        local id_lower="${repo_id,,}"
        [[ "$id_lower" == *"baseos"* || "$url" == *"/baseos/"* ]] && baseos_found=1
        [[ "$id_lower" == *"appstream"* || "$url" == *"/appstream/"* ]] && appstream_found=1
        [[ "$id_lower" == *"uek"* || "$url" == *"/uek"* ]] && uek_found=1
    done

    if [[ "$distro" == "Oracle Linux" ]]; then
        [[ $baseos_found -eq 0 ]] && missing_repos+=("BaseOS")
        [[ $appstream_found -eq 0 ]] && missing_repos+=("AppStream")
        [[ $uek_found -eq 0 ]] && echo -e "${YELLOW}[WARN]${NC} Falta repositorio UEK (Recomendado pero no bloqueante)."
    elif [[ "$distro" == "RHEL" ]]; then
        [[ $baseos_found -eq 0 ]] && missing_repos+=("BaseOS")
        [[ $appstream_found -eq 0 ]] && missing_repos+=("AppStream")
    fi

    # Reporte de Faltantes Esenciales
    if [[ ${#missing_repos[@]} -gt 0 ]]; then
        echo -e "\n${RED}[ERROR]${NC} Faltan repositorios esenciales: ${missing_repos[*]}"
        echo -e "${CYAN}[SOLUCIÓN]${NC} Copia y pega estos comandos para arreglarlo:"

        if [[ "$distro" == "Oracle Linux" ]]; then
            [[ $baseos_found -eq 0 ]] && echo -e "${MAGENTA}sudo dnf config-manager --add-repo https://yum.oracle.com/repo/OracleLinux/OL9/baseos/latest/x86_64/${NC}"
            [[ $appstream_found -eq 0 ]] && echo -e "${MAGENTA}sudo dnf config-manager --add-repo https://yum.oracle.com/repo/OracleLinux/OL9/appstream/x86_64/${NC}"
        elif [[ "$distro" == "RHEL" ]]; then
            echo -e "${MAGENTA}sudo subscription-manager repos --enable=rhel-9-for-x86_64-baseos-rpms${NC}"
            echo -e "${MAGENTA}sudo subscription-manager repos --enable=rhel-9-for-x86_64-appstream-rpms${NC}"
        fi

        echo ""
        log_failure "Faltan repositorios base: ${missing_repos[*]}"
    else
        log_success "Todos los repositorios base están presentes."
        mark_success "validate_repos_commons"
    fi

    ((total_checks++))
}

validate_firewall_off() {
    echo -e "${YELLOW}--- Validación de Firewall Desactivado ---${NC}"
    log "Validando estado del firewall..."

    local fw_status
    fw_status=$(systemctl is-active firewalld 2>/dev/null)

    # Si no existe / no aplica, lo consideramos OK (como ya venías manejando "unknown")
    if [[ "$fw_status" == "inactive" || "$fw_status" == "unknown" ]]; then
        echo -e "${GREEN}[OK]${NC} Firewall está desactivado (estado: ${fw_status})"
        ((passed_checks++))
        ((total_checks++))
        return 0
    fi

    # Si está activo, intentamos remediar automáticamente
    if [[ "$fw_status" == "active" ]]; then
        echo -e "${RED}[ERROR]${NC} Firewall se encuentra activo (estado: ${fw_status})"
        echo -e "${CYAN}[ACCIÓN]${NC} Se procederá a desactivarlo automáticamente."
        echo -e "${CYAN}[COMANDO]${NC} sudo systemctl stop firewalld"
        echo -e "${CYAN}[COMANDO]${NC} sudo systemctl disable firewalld"

        # Intento de remediación (sin perder la mensajística)
        if sudo systemctl stop firewalld 2>/dev/null && sudo systemctl disable firewalld 2>/dev/null; then
            # Revalidación
            fw_status=$(systemctl is-active firewalld 2>/dev/null)
            if [[ "$fw_status" == "inactive" || "$fw_status" == "unknown" ]]; then
                echo -e "${GREEN}[OK]${NC} Firewall desactivado exitosamente (estado final: ${fw_status})"
                ((passed_checks++))
            else
                echo -e "${RED}[ERROR]${NC} Se ejecutaron los comandos, pero el firewall aún no quedó desactivado (estado final: ${fw_status})"
                echo -e "${CYAN}[SOLUCIÓN]${NC} Ejecuta manualmente y revisa errores/lockdown:"
                echo -e "${MAGENTA}sudo systemctl stop firewalld${NC}"
                echo -e "${MAGENTA}sudo systemctl disable firewalld${NC}"
                echo -e "${MAGENTA}sudo systemctl status firewalld -l${NC}\n"
                ((failed_checks++))
            fi
        else
            echo -e "${RED}[ERROR]${NC} No fue posible desactivar el firewall automáticamente (falló sudo/systemctl)."
            echo -e "${CYAN}[SOLUCIÓN]${NC} Ejecuta manualmente:"
            echo -e "${MAGENTA}sudo systemctl stop firewalld${NC}"
            echo -e "${MAGENTA}sudo systemctl disable firewalld${NC}"
            echo -e "${MAGENTA}sudo systemctl status firewalld -l${NC}\n"
            ((failed_checks++))
        fi

        ((total_checks++))
        return 0
    fi

    # Cualquier otro estado raro lo tratamos como fallo (para no “pasar” sin saber)
    echo -e "${RED}[ERROR]${NC} Estado inesperado de firewalld: '${fw_status}'"
    echo -e "${CYAN}[SOLUCIÓN]${NC} Revisa manualmente:"
    echo -e "${MAGENTA}systemctl status firewalld -l${NC}\n"
    ((failed_checks++))
    ((total_checks++))
    return 1
}

function validate_hosts_file() {
    echo -e "${YELLOW}--- Validación de asignaciones en /etc/hosts ---${NC}"
    log "Verificando resolución local de nombres..."

    local missing_entries=""
    local missing_count=0

    # Leer el archivo de inventario validado
    while IFS=',' read -r role role_order hostname ip _; do
        # Ignorar comentarios o líneas vacías
        [[ "$role" =~ ^#.*$ || -z "$role" ]] && continue
        
        # Validar si la IP existe en /etc/hosts (búsqueda literal con -F)
        # Nota: Buscamos la IP para evitar falsos positivos de hostnames parciales
        if ! grep -qF "$ip" /etc/hosts; then
            echo -e "${RED}[ERROR]${NC} Falta: ${CYAN}$hostname ($ip)${NC}"
            # Acumulamos la línea faltante
            missing_entries+="${ip} ${hostname} ${hostname}.localdomain\n"
            ((missing_count++))
        else
            echo -e "${GREEN}[OK]${NC} Encontrado: $hostname -> $ip"
        fi
    done < "$K8S_INVENTORY"

    # Si encontramos faltantes, mostramos el comando mágico
    if [[ $missing_count -gt 0 ]]; then
        
        echo
        echo -e "${CYAN}[SOLUCIÓN]${NC} Ejecuta este bloque para agregar los nodos faltantes de una sola vez:"
        echo "----------------------------------------------------------------"
        # Generamos el comando con 'tee -a' que funciona con sudo y evita problemas de permisos
        echo -e "${MAGENTA}cat <<EOF | sudo tee -a /etc/hosts"
        echo -e "${missing_entries}EOF${NC}"
        echo "----------------------------------------------------------------"
        
        log_failure "Faltan $missing_count entradas en /etc/hosts"
    else
        log_success "Archivo /etc/hosts sincronizado con inventario"
    fi
    ((total_checks++))
}

function validate_kernel() {

    # =========================================================
    # 1. CACHE
    # =========================================================
    if check_cache "validate_kernel"; then
        return
    fi

    ((total_checks++))

    echo -e "\n${YELLOW}--- Validación de versión del Kernel ---${NC}"
    log "Validando capacidad del kernel (versión mínima requerida)..."

    # =========================================================
    # 2. DETECTAR DISTRIBUCIÓN
    # =========================================================
    local distro
    if grep -qi "Oracle" /etc/os-release; then
        distro="OL"
    elif grep -qi "Red Hat" /etc/os-release; then
        distro="RHEL"
    else
        echo -e "${RED}[ERROR]${NC} Distribución no soportada."
        log_failure "validate_kernel"
        return 1
    fi

    # =========================================================
    # 3. OBTENER KERNEL ACTUAL
    # =========================================================
    local current_kernel current_version
    current_kernel=$(uname -r)
    current_version=$(echo "$current_kernel" | cut -d- -f1 | cut -d. -f1,2)

    # =========================================================
    # 4. DEFINIR REQUISITOS
    # =========================================================
    local min_version kernel_flavor

    if [[ "$distro" == "OL" ]]; then
        if echo "$current_kernel" | grep -qi "uek"; then
            kernel_flavor="UEK (Unbreakable Enterprise Kernel)"
            min_version="5.4"
        else
            kernel_flavor="RHCK (Red Hat Compatible Kernel)"
            min_version="4.18"
        fi
    else
        kernel_flavor="Kernel RHEL"
        min_version="4.18"
    fi

    echo -e "${CYAN}[INFO]${NC} Distribución detectada  : ${MAGENTA}${distro}${NC}"
    echo -e "${CYAN}[INFO]${NC} Kernel en uso           : ${MAGENTA}${kernel_flavor}${NC}"
    echo -e "${CYAN}[INFO]${NC} Versión actual          : ${MAGENTA}${current_kernel}${NC}"
    echo -e "${CYAN}[INFO]${NC} Versión mínima requerida: ${MAGENTA}${min_version}+${NC}"

    # =========================================================
    # 5. VALIDAR VERSIÓN (ROBUSTO)
    # =========================================================
    if [[ "$(printf '%s\n' "$min_version" "$current_version" | sort -V | head -n1)" == "$min_version" ]]; then
        echo -e "${GREEN}[OK]${NC} El kernel cumple con la versión mínima requerida."
        log_success "validate_kernel"
        mark_success "validate_kernel"
    else
        echo -e "${RED}[ERROR]${NC} El kernel ${MAGENTA}${current_version}${NC} es inferior al mínimo requerido (${min_version})."
        echo -e "${CYAN}[ACCIÓN REQUERIDA]${NC} Solicitar actualización del kernel al equipo de infraestructura."
        log_failure "validate_kernel"
        return 1
    fi
}

function validate_system_updates() {
    # 1. Check Caché
    if check_cache "validate_system_updates"; then return; fi

    echo -e "${YELLOW}--- Validación de Actualizaciones del Sistema ---${NC}"
    log "Verificando actualizaciones de Kernel (Modo No-Bloqueante)..."

    # =========================================================
    # 1. SKIPEADOR: Si kernel OK (cache o previo), no dnf
    # =========================================================
    local kernel_ok="${K8S_CACHE_DIR}/validate_kernel.ok"
    if [[ -f "${kernel_ok}" ]]; then
        echo -e "${GREEN}OK${NC} Kernel cumple mínimo. Skip check-update (evita Spacewalk)."
        log_success "Kernel OK - Skip updates check"
        ((total_checks++))
        return
    fi

    # =========================================================
    # 2. VALIDACIÓN DE RED
    # =========================================================
    local test_url=""
    
    if grep -qi "Oracle" /etc/os-release; then
        test_url="https://yum.oracle.com"
    elif grep -qi "Red Hat" /etc/os-release; then
        test_url="https://cdn.redhat.com" 
    else
        test_url="https://google.com"
    fi

    if ! curl -I -m 5 "${test_url}" &>/dev/null; then
        echo -e "${RED}[ERROR]${NC} No hay salida a internet hacia los repositorios en ${test_url}"
        log_failure "Sin conexión a internet."
        return
    fi

    # =========================================================
    # 3. MENSAJE DE VALIDACIÓN DE KERNEL
    # =========================================================

    echo -e "${GREEN}[OK]${NC} Kernel ya validado previamente. No se revisan actualizaciones de kernel."
    log_success "Kernel cumple versión mínima (no se valida update)"
    mark_success "validate_system_updates"
    ((total_checks++))
}

function validate_selinux() {
    echo -e "${YELLOW}--- Validación de SELinux ---${NC}"
    log "Verificando estado de SELinux..."

    local status
    status=$(getenforce 2>/dev/null)
    if [[ "$status" != "Disabled" ]]; then
        echo -e "${YELLOW}[AUTO-FIX]${NC} SELinux está activo (${status}). Aplicando corrección..."

        # 1. Corrección Temporal (Para que el script pueda seguir si fuera necesario)
        if [[ "$status" == "Enforcing" ]]; then
            echo -e "${YELLOW}[WARN]${NC} Modo Enforcing detectado - alto riesgo K8s."
        fi
        sudo setenforce 0 2>/dev/null

        # 2. Corrección Permanente (Config)
        # Desbloquear si tiene atributo 'i'
        if lsattr /etc/selinux/config 2>/dev/null | grep -q "i"; then
            sudo chattr -i /etc/selinux/config
        fi

        sudo sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config

        echo -e "${GREEN}[OK]${NC} Configuración aplicada. Se requerirá reinicio al final."
        declare -g PENDING_REBOOT=1

        # IMPORTANTE: Usamos log_success para NO detener el script ahora.
        # El reinicio se solicitará al terminar todas las validaciones.
        log_success "SELinux corregido (Pendiente Reinicio)"
    else
        echo -e "${GREEN}[OK]${NC} SELinux está deshabilitado."
        log_success "validate_selinux"
    fi
    
    mark_success "validate_selinux"
    ((total_checks++))
}

function validate_swap() {
    echo -e "${YELLOW}=== Validación de Estado Swap ===${NC}"
    log "Verificando estado actual de swap..."
    
    local swap_active swap_fstab swap_devices

    # Detectar estado de swap
    swap_active=$(swapon --noheadings --show)
    swap_fstab=$(grep -v '^#' /etc/fstab | grep -i swap)

    if [[ -z "$swap_active" && -z "$swap_fstab" ]]; then
        echo -e "${GREEN}[OK]${NC} Swap completamente desactivado."
        log_success "Swap validado correctamente"
        return 0
    fi

    echo -e "${YELLOW}[AUTO-FIX]${NC} Detectada configuración de Swap. Desactivando..."

    # 1. Desactivación Temporal (Inmediata)
    if [[ -n "$swap_active" ]]; then
        sudo swapoff -a
        echo -e " - Swap desactivado en tiempo de ejecución."
    fi

    # 2. Desactivación Permanente (fstab)
    if [[ -n "$swap_fstab" ]]; then
        # Comentar la línea de swap en fstab
        sudo sed -i '/ swap / s/^/#/' /etc/fstab
        # Asegurar por si el formato es distinto (tabuladores, etc)
        sudo sed -i '/swap/ s/^/#/' /etc/fstab
        echo -e " - Swap comentado en /etc/fstab."
    fi

    echo -e "${GREEN}[OK]${NC} Correcciones aplicadas."
    declare -g PENDING_REBOOT=1

    # No detenemos el script, marcamos éxito condicional
    log_success "Swap corregido (Pendiente Reinicio)"
}

function validate_time_sync() {
    # 1. Check Caché
    if check_cache "validate_time_sync"; then return; fi

    echo -e "${YELLOW}--- Validación de zona horaria y sincronización NTP ---${NC}"

    # =====================
    # Zona horaria dinámica (por país)
    # =====================
    TIMEZONE_FILE="${K8S_CACHE_DIR}/validate_timezone.ok"

    if [[ -f "$TIMEZONE_FILE" ]]; then
        # Leer el valor ya configurado
        CLIENT_TZ=$(cat "$TIMEZONE_FILE")
        echo -e "${CYAN}[INFO]${NC} Zona horaria cargada desde caché: ${MAGENTA}${CLIENT_TZ}${NC}"
    else
        echo
        echo -e "${YELLOW}--- Configuración inicial de zona horaria ---${NC}"
        echo "Seleccione su país:"
        echo "  [1] México"
        echo "  [2] Perú"
        echo "  [3] Colombia"
        echo "  [4] Bolivia"
        echo "  [5] Uruguay"
        read_with_default tz_choice "Opción (1-5): " "1"

        case "$tz_choice" in
            1) CLIENT_TZ="America/Mexico_City" ;;
            2) CLIENT_TZ="America/Lima" ;;
            3) CLIENT_TZ="America/Bogota" ;;
            4) CLIENT_TZ="America/La_Paz" ;;
            5) CLIENT_TZ="America/Montevideo" ;;
            *) CLIENT_TZ="America/Mexico_City" ;;
        esac

        echo -e "${GREEN}[OK]${NC} Zona horaria seleccionada: ${MAGENTA}${CLIENT_TZ}${NC}"
        echo "$CLIENT_TZ" > "$TIMEZONE_FILE"
    fi

    # 1. Validación de zona horaria
    log "Verificando zona horaria..."
    local timezone
    timezone=$(timedatectl | grep "Time zone" | awk '{print $3}')

    if [[ "$timezone" == "${CLIENT_TZ}" ]]; then
        log_success "Zona horaria correcta: $timezone"
    else
        echo -e "${YELLOW}[AUTO-FIX]${NC} Zona horaria actual: ${MAGENTA}${timezone}${NC}"
        echo -e "${CYAN}[ACCIÓN]${NC} Ajustando automáticamente a: ${MAGENTA}${CLIENT_TZ}${NC}"

        if sudo timedatectl set-timezone "${CLIENT_TZ}" 2>/dev/null; then
            echo -e "${GREEN}[OK]${NC} Zona horaria actualizada a ${MAGENTA}${CLIENT_TZ}${NC}"
            log_success "Zona horaria corregida automáticamente a ${CLIENT_TZ}"
        else
            echo -e "${RED}[ERROR]${NC} No se pudo ajustar automáticamente la zona horaria."
            echo -e "${CYAN}[SOLUCIÓN]${NC} Ejecute manualmente:"
            echo -e "${MAGENTA}sudo timedatectl set-timezone ${CLIENT_TZ}${NC}\n"
            log_failure "Error ajustando zona horaria a ${CLIENT_TZ}"
        fi
    fi

    # 2. Validación del servicio NTP (chronyd)
    log "Verificando estado de chronyd..."
    if systemctl is-active --quiet chronyd; then
        echo -e "${GREEN}[OK]${NC} Servicio chronyd activo"
        log_success "validate_chronyd"
    else
        echo -e "${RED}[ERROR]${NC} Servicio chronyd INACTIVO"
        echo -e "${CYAN}[SOLUCIÓN]${NC} sudo systemctl enable --now chronyd"
        log_failure "validate_chronyd"
    fi

    # 3. Validación de configuración NTP local
    log "Verificando configuración local de NTP en /etc/chrony.conf..."
    if grep -qE "^(server 127\.127\.1\.0|local stratum)" /etc/chrony.conf; then
        echo -e "${GREEN}[OK]${NC} Configuración local de NTP detectada"
        log_success "validate_chrony_conf"
    else
        echo -e "${YELLOW}[AUTO-FIX]${NC} No se detectó configuración local de NTP"
        echo -e "${CYAN}[ACCIÓN]${NC} Agregando 'local stratum 10' automáticamente"

        # Evitar duplicados
        if ! grep -q "^local stratum 10" /etc/chrony.conf; then
            echo "local stratum 10" | sudo tee -a /etc/chrony.conf > /dev/null
        fi

        # Reiniciar servicio
        if sudo systemctl restart chronyd 2>/dev/null; then
            sleep 2
            if systemctl is-active --quiet chronyd; then
                echo -e "${GREEN}[OK]${NC} Configuración NTP local aplicada correctamente"
                log_success "chrony configurado (local stratum 10)"
            else
                echo -e "${RED}[ERROR]${NC} chronyd no quedó activo tras el reinicio"
                log_failure "chronyd no activo después del auto-fix"
            fi
        else
            echo -e "${RED}[ERROR]${NC} Falló el reinicio de chronyd"
            log_failure "fallo reinicio chronyd"
        fi
    fi

    mark_success "validate_time_sync"
    ((total_checks++))
}

function validate_essential_packages() {
    # 1. Check Caché
    if check_cache "validate_essential_packages"; then return; fi

    echo -e "${YELLOW}--- Validación de paquetes esenciales (Completo) ---${NC}"
    log "Verificando herramientas del sistema..."

    # Lista de paquetes faltantes (para el reporte final)
    local missing_pkgs_names=()
    local missing_tools_labels=()

    # ---------------------------------------------------------
    # GRUPO 1: Herramientas Binarias (Verificación Rápida)
    # Formato: "comando_a_probar:paquete_a_instalar"
    # ---------------------------------------------------------
    local binary_tools=(
        "curl:curl"
        "wget:wget"
        "vim:vim-enhanced"
        "jq:jq"
        "dos2unix:dos2unix"
        "tree:tree"
        "git:git"
        "bc:bc"
        "awk:awk"
        "ping:iputils"       # El comando es ping, el paquete es iputils
        "envsubst:gettext"   # El comando es envsubst, el paquete es gettext
        "ifconfig:net-tools" # El comando es ifconfig, el paquete es net-tools
        "tar:tar"
        "traceroute:traceroute"
    )

    for item in "${binary_tools[@]}"; do
        local cmd="${item%%:*}"
        local pkg="${item##*:}"

        if command -v "$cmd" &>/dev/null; then
            echo -e "${GREEN}[OK]${NC} ${cmd}"
        else
            echo -e "${RED}[ERROR]${NC} Falta binario: ${CYAN}${cmd}${NC}"
            missing_pkgs_names+=("$pkg")
            missing_tools_labels+=("$cmd")
        fi
    done

    # ---------------------------------------------------------
    # GRUPO 2: Casos Especiales (Lógica compleja conservada)
    # ---------------------------------------------------------
    
    # Check: Netcat (nc o ncat)
    if command -v nc &>/dev/null || command -v ncat &>/dev/null; then
        echo -e "${GREEN}[OK]${NC} nc/ncat"
    else
        echo -e "${RED}[ERROR]${NC} Falta: nc/ncat"
        missing_pkgs_names+=("nmap-ncat")
        missing_tools_labels+=("nc")
    fi

    # Check: DNF Utils (puede llamarse yum-utils o dnf-utils)
    # Primero probamos si el paquete está instalado (más seguro para utils)
    if rpm -q dnf-utils &>/dev/null || rpm -q yum-utils &>/dev/null; then
        echo -e "${GREEN}[OK]${NC} dnf-utils"
    else
        echo -e "${RED}[ERROR]${NC} Falta: dnf-utils"
        missing_pkgs_names+=("dnf-utils")
        missing_tools_labels+=("dnf-utils")
    fi

    # ---------------------------------------------------------
    # GRUPO 3: Plugins y Librerías (Requieren rpm -q obligatorio)
    # ---------------------------------------------------------
    local rpm_tools=(
        "bash-completion"
        "dnf-plugins-core"
        "nfs-utils"
    )

    for pkg in "${rpm_tools[@]}"; do
        if rpm -q "$pkg" &>/dev/null; then
            echo -e "${GREEN}[OK]${NC} ${pkg}"
        else
            echo -e "${RED}[ERROR]${NC} Falta paquete: ${CYAN}${pkg}${NC}"
            missing_pkgs_names+=("$pkg")
            missing_tools_labels+=("$pkg")
        fi
    done

    # ---------------------------------------------------------
    # RESUMEN, INSTALACIÓN AUTOMÁTICA Y CACHÉ
    # ---------------------------------------------------------

    if [[ ${#missing_pkgs_names[@]} -gt 0 ]]; then
        # Crear lista única de paquetes para instalar
        local unique_install_list
        local -a unique_install_array=()
        unique_install_list=$(printf '%s\n' "${missing_pkgs_names[@]}" | sort -u | paste -sd ' ' -)
        while IFS= read -r pkg; do
            [[ -n "$pkg" ]] && unique_install_array+=("$pkg")
        done < <(printf '%s\n' "${missing_pkgs_names[@]}" | sort -u)

        echo -e "\n${YELLOW}--- Instalando paquetes esenciales faltantes ---${NC}"
        echo -e "${CYAN}[INFO]${NC} Se instalarán los siguientes paquetes:"
        echo -e "  ${MAGENTA}${unique_install_list}${NC}\n"

        echo -e "${CYAN}[INFO]${NC} Ejecutando: ${MAGENTA}dnf install -y ${unique_install_list}${NC}\n"

        # Ejecutar instalación (puede requerir internet/repos)
        if dnf install -y "${unique_install_array[@]}"; then
            echo -e "${GREEN}[OK]${NC} Paquetes esenciales instalados correctamente."
            log_success "Paquetes esenciales instalados: ${unique_install_list}"

            # Activar bash-completion inmediatamente (CRÍTICO en SSH)
            if [ -f /etc/profile.d/bash_completion.sh ]; then
                source /etc/profile.d/bash_completion.sh
                echo -e "${GREEN}[OK]${NC} bash-completion activado en la sesión actual"
            fi

            # Tras instalar con éxito, marcamos la validación como completada
            mark_success "validate_essential_packages"
        else
            echo -e "${RED}[ERROR]${NC} Falló la instalación de paquetes esenciales."
            log_failure "Error al instalar paquetes esenciales: ${unique_install_list}"
        fi

    else
        log_success "Todas las herramientas esenciales (binarios y plugins) están presentes."

        # Activar bash-completion si ya existía pero no estaba cargado
        if [ -f /etc/profile.d/bash_completion.sh ]; then
            source /etc/profile.d/bash_completion.sh
        fi

        mark_success "validate_essential_packages"
    fi

    ((total_checks++))
}

function validate_network_connectivity() {
    echo -e "${YELLOW}--- Validación de conectividad entre nodos (Paralelo) ---${NC}"
    log "Iniciando validación de conectividad (Ping + SSH Port 22)..."

    # 1. Obtener IPs locales para evitar auto-ping
    local my_ips
    my_ips=$(hostname -I 2>/dev/null)
    # Agregamos 127.0.0.1 y IPs detectadas por ip addr
    my_ips+=" 127.0.0.1 $(ip addr show | grep inet | awk '{print $2}' | cut -d/ -f1)"

    local pids=()
    local servers_to_check=()
    
    # 2. Preparar lista de nodos
    while IFS=',' read -r s_role s_order s_host s_ip extra; do
        [[ "$s_role" =~ ^#.*$ || -z "$s_role" ]] && continue
        
        # Ignorar mi propia IP
        if echo "$my_ips" | grep -qw "$s_ip"; then
            continue
        fi
        servers_to_check+=("$s_ip|$s_host")
    done < "$K8S_INVENTORY"

    if [[ ${#servers_to_check[@]} -eq 0 ]]; then
        echo -e "${CYAN}[INFO]${NC} No hay otros nodos para verificar."
        ((total_checks++))
        return
    fi

    echo -e "${CYAN}[INFO]${NC} Verificando ${#servers_to_check[@]} nodos simultáneamente..."

    # 3. EJECUCIÓN PARALELA
    for item in "${servers_to_check[@]}"; do
        local target_ip="${item%%|*}"
        local target_host="${item##*|}"

        (
            local node_error=0
            
            # A) Check Ping (Rápido)
            if ping -c 2 -W 2 "$target_ip" &>/dev/null; then
                echo -e "${GREEN}[OK]${NC} Ping   -> ${target_host} (${target_ip})"
            else
                echo -e "${RED}[FAIL]${NC} Ping   -> ${target_ip}"
                node_error=1
            fi

            # B) Check SSH (Puerto 22)
            # Usamos /dev/tcp nativo de bash para no depender de nc/ncat si no queremos
            if timeout 3 bash -c "</dev/tcp/$target_ip/22" &>/dev/null; then
                echo -e "${GREEN}[OK]${NC} SSH:22 -> ${target_host}"
            else
                echo -e "${YELLOW}[WARN]${NC} SSH:22 -> ${target_ip} (Cerrado/Filtrado)"
                # node_error=1 # Descomentar si quieres que SSH sea obligatorio
            fi

            exit $node_error
        ) &
        
        pids+=($!)
    done

    # 4. Esperar a todos los procesos (WAIT)
    local global_fail=0
    for pid in "${pids[@]}"; do
        wait "$pid"
        if [[ $? -ne 0 ]]; then global_fail=1; fi
    done

    # 5. RESUMEN Y SUGERENCIAS (Aquí están de vuelta los comandos)
    if [[ $global_fail -eq 0 ]]; then
        log_success "Conectividad total verificada exitosamente."
    else
        echo -e "\n${CYAN}[GUÍA DE SOLUCIÓN]${NC} Se detectaron problemas de red. Revisa lo siguiente:"
        
        echo -e "1. ${YELLOW}Si falló el PING:${NC}"
        echo -e "   - Verifica que la IP sea correcta en ${K8S_INVENTORY}."
        echo -e "   - Habilita ICMP en el firewall del destino:"
        echo -e "${MAGENTA}sudo firewall-cmd --permanent --add-protocol=icmp && sudo firewall-cmd --reload${NC}"
        
        echo -e "2. ${YELLOW}Si falló el PUERTO 22 (SSH):${NC}"
        echo -e "   - Verifica que el servicio SSH esté activo:"
        echo -e "${MAGENTA}sudo systemctl status sshd${NC}"
        echo -e "   - Permite el servicio en el firewall:"
        echo -e "${MAGENTA}sudo firewall-cmd --permanent --add-service=ssh && sudo firewall-cmd --reload${NC}"
        
        log_failure "Falló la conectividad con uno o más nodos."
    fi

    ((total_checks++))
}

function update_env_var() {

    local key="$1"
    local val="$2"

    # garantizar existencia del archivo
    [[ -f "${K8S_VARIABLES}" ]] || install -m 600 /dev/null "${K8S_VARIABLES}"

    # ¿ya existe la variable?
    if grep -q "^${key}=" "${K8S_VARIABLES}" 2>/dev/null; then

        local current_val
        current_val=$(grep "^${key}=" "${K8S_VARIABLES}" | cut -d'=' -f2-)

        if [[ "$current_val" != "$val" ]]; then
            sed -i "s|^${key}=.*|${key}=${val}|" "${K8S_VARIABLES}"
            echo -e "  [UPD] ${CYAN}${key}${NC} actualizada a ${val}"
            ((updates_count++))
        fi

    else
        printf '%s=%s\n' "$key" "$val" >> "${K8S_VARIABLES}"
        echo -e "  [NEW] ${GREEN}${key}${NC} agregada."
        ((adds_count++))
    fi
}

function generate_environment_vars() {

    # 1. Cache
    if check_cache "generate_environment_vars"; then return; fi

    echo -e "${YELLOW}--- Generando variables de entorno (${K8S_VARIABLES}) ---${NC}"
    log "Sincronizando variables en ${K8S_VARIABLES}..."

    local updates_count=0
    local adds_count=0

    # asegurar archivo limpio (determinístico)
    : > "${K8S_VARIABLES}"
    chmod 600 "${K8S_VARIABLES}"

    # ==============================
    # Variables base del entorno APIM
    # ==============================
    update_env_var "K8S_BASE_DIR" "${K8S_BASE_DIR}"
    update_env_var "K8S_VARIABLES" "${K8S_VARIABLES}"
    update_env_var "K8S_INVENTORY" "${K8S_INVENTORY}"
    update_env_var "K8S_CACHE_DIR" "${K8S_CACHE_DIR}"
    update_env_var "YAML_BASE_PATH" "${YAML_BASE_PATH}"

    # ===== evitar subshell =====
    exec 3< "$K8S_INVENTORY"

    while IFS=',' read -r role order hostname ip extra <&3; do

        [[ "$role" =~ ^#.*$ || -z "$role" || -z "$order" || -z "$ip" ]] && continue

        local env_prefix=""
        case "$role" in
            BALANCEADOR) env_prefix="HAPROXY" ;;
            MANAGER)     env_prefix="MASTER" ;;
            WORKER)      env_prefix="WORKER" ;;
            *) continue ;;
        esac

        local padded_order
        padded_order=$(printf "%02d" "$order")

        update_env_var "IP_${env_prefix}_${padded_order}" "$ip"
        update_env_var "HOSTNAME_${env_prefix}_${padded_order}" "$hostname"

    done

    exec 3<&-

    # Variables fijas
    update_env_var "NGX_SVC_HTTP_NODEPORT" "31910"
    update_env_var "NGX_SVC_HTTPS_NODEPORT" "31988"
    update_env_var "KUBERNETES_VERSION" "v1.35"

    # ---------- VALIDACIÓN REAL (LA CLAVE) ----------
    if grep -qE '^[A-Z0-9_]+=' "${K8S_VARIABLES}"; then

        set -a
        . "${K8S_VARIABLES}"
        set +a

        if [[ $adds_count -eq 0 && $updates_count -eq 0 ]]; then
            echo -e "${GREEN}[OK]${NC} Las variables de entorno ya estaban sincronizadas."
        else
            log_success "Variables sincronizadas (Agregadas: $adds_count, Actualizadas: $updates_count)"
        fi

        mark_success "generate_environment_vars"

    else
        echo
        echo -e "${YELLOW}[WARN]${NC} No se pudieron generar variables de entorno válidas."
        echo -e "${YELLOW}          El sistema fue validado, pero la instalación posterior podría fallar.${NC}"
        echo -e "${YELLOW}          Revise ${K8S_VARIABLES} y ${K8S_INVENTORY}.${NC}"
        echo

        # NO contar como error crítico
        FAILED_CHECKS+=("generate_environment_vars (soft-fail)")
    fi

    ((total_checks++))
}

function validate_all_hosts() {
    echo -e "${YELLOW}=== INICIANDO VALIDACIONES COMUNES ===${NC}"
    local common_checks=(
        validate_hosts_file
        validate_repos_commons
        validate_firewall_off
        validate_kernel
        validate_system_updates
        validate_selinux
        validate_swap
        validate_time_sync
        validate_essential_packages
        validate_network_connectivity
        generate_environment_vars
    )
    
    for check in "${common_checks[@]}"; do
        $check
    done
    
    echo -e "${YELLOW}=== VALIDACIONES COMUNES COMPLETADAS: ${GREEN}$passed_checks✓ ${RED}$failed_checks✗ ===${NC}"
}

# =====================
# Funciones por Rol
# =====================
function validate_repos_balancer() {
    echo -e "${YELLOW}--- Validación de repositorio para HAProxy (BALANCEADOR) ---${NC}"
    log "Verificando disponibilidad del paquete 'haproxy'..."

    local target_url=""
    local advice_cmd=""
    
    # Detectar distro para definir la URL a desbloquear y el comando de arreglo
    if grep -qi "Oracle" /etc/os-release; then
        target_url="https://yum.oracle.com"
        advice_cmd="sudo dnf config-manager --enable ol9_appstream"
    else
        target_url="https://cdn.redhat.com"
        advice_cmd="sudo subscription-manager repos --enable=rhel-9-for-x86_64-appstream-rpms"
    fi

    # 1. Intentar listar el paquete (Cache primero, luego red)
    if dnf list haproxy -C &>/dev/null || dnf list haproxy &>/dev/null; then
        echo -e "${GREEN}[OK]${NC} Paquete 'haproxy' disponible para instalación."
        log_success "Repo con HAProxy disponible"
    else
        echo -e "${RED}[ERROR]${NC} No se encontró el paquete 'haproxy'."
        
        # 2. Diagnóstico de Red / Configuración
        echo -e "\n${YELLOW}======================================================${NC}"
        echo -e "${YELLOW} 🛑 REQUISITO DE RED / CONFIGURACIÓN${NC}"
        echo -e "${YELLOW}======================================================${NC}"
        echo -e "HAProxy pertenece al repositorio 'AppStream' del sistema operativo."
        echo -e "1. ${CYAN}Si tienes internet:${NC} Verifica que el repo esté habilitado:"
        echo -e "   -> ${MAGENTA}${advice_cmd}${NC}"
        echo -e "2. ${CYAN}Si es una red restringida:${NC} Solicita salida a:"
        echo -e "   -> URL: ${MAGENTA}${target_url}${NC} (Puerto 443)\n"
        log_failure "Falta paquete haproxy en repos"
    fi
    ((total_checks++))

    # --- Keepalived: solo necesario si hay más de un balanceador ---
    if [[ $(count_balancers) -gt 1 ]]; then
        echo ""
        log "Verificando disponibilidad del paquete 'keepalived' (HA activo: múltiples balanceadores)..."
        if dnf list keepalived -C &>/dev/null || dnf list keepalived &>/dev/null; then
            echo -e "${GREEN}[OK]${NC} Paquete 'keepalived' disponible para instalación."
            log_success "Repo con keepalived disponible"
        else
            echo -e "${RED}[ERROR]${NC} No se encontró el paquete 'keepalived'."
            echo -e "\n${YELLOW}======================================================${NC}"
            echo -e "${YELLOW} 🛑 REQUISITO DE RED / CONFIGURACIÓN${NC}"
            echo -e "${YELLOW}======================================================${NC}"
            echo -e "keepalived generalmente pertenece al repositorio 'AppStream' del sistema operativo."
            echo -e "1. ${CYAN}Si tienes internet:${NC} Verifica que el repo esté habilitado:"
            echo -e "   -> ${MAGENTA}${advice_cmd}${NC}"
            echo -e "2. ${CYAN}Si es una red restringida:${NC} Solicita salida a:"
            echo -e "   -> URL: ${MAGENTA}${target_url}${NC} (Puerto 443)\n"
            log_failure "Falta paquete keepalived en repos"
        fi
        ((total_checks++))
    fi
}

function validate_haproxy() {
    echo -e "${YELLOW}--- Validación de HAProxy (Servicio y Config) ---${NC}"
    log "Verificando instalación y estado de HAProxy..."

    # 1. Verificación de Binario
    if ! command -v haproxy &>/dev/null; then
        echo -e "${YELLOW}--- Instalando y habilitando HAProxy automáticamente ---${NC}"

        local install_cmd_haproxy="dnf install -y haproxy"
        local enable_cmd="systemctl enable --now haproxy"

        echo -e "${CYAN}[INFO]${NC} Ejecutando instalación:"
        echo -e "  ${MAGENTA}${install_cmd_haproxy}${NC}\n"
        if ! ${install_cmd_haproxy}; then
            echo -e "${RED}[ERROR]${NC} Falló la instalación de HAProxy."
            log_failure "Error instalando haproxy con: ${install_cmd_haproxy}"
            ((total_checks++))
            return
        fi

        echo -e "${CYAN}[INFO]${NC} Habilitando y arrancando servicio:"
        echo -e "  ${MAGENTA}${enable_cmd}${NC}\n"
        if ! ${enable_cmd}; then
            echo -e "${RED}[ERROR]${NC} Falló al habilitar/iniciar el servicio haproxy."
            log_failure "Error habilitando/iniciando haproxy con: ${enable_cmd}"
            ((total_checks++))
            return
        fi

        echo -e "${GREEN}[OK]${NC} HAProxy instalado y servicio habilitado/activo."
        # No salimos aquí: seguimos para validar versión y config
    fi

    # Mostrar versión (Informativo)
    local haproxy_version
    haproxy_version=$(haproxy -v 2>&1 | head -n 1 | awk '{print $3}')
    echo -e "${GREEN}[OK]${NC} Instalado: Versión ${CYAN}${haproxy_version}${NC}"

    # 2. Verificación de Archivo de Configuración
    local cfg_file="/etc/haproxy/haproxy.cfg"
    
    if [[ ! -f "$cfg_file" ]]; then
        echo -e "${RED}[ERROR]${NC} No existe ${cfg_file}"
        echo -e "${CYAN}[SOLUCIÓN]${NC} Copiar ejemplo predeterminado:"
        echo -e "${MAGENTA}sudo cp /usr/share/doc/haproxy*/examples/haproxy.cfg $cfg_file${NC}\n"
        log_failure "Falta haproxy.cfg"
    else
        # Validar sintaxis (haproxy -c)
        if haproxy -c -f "$cfg_file" &>/dev/null; then
            echo -e "${GREEN}[OK]${NC} Sintaxis de haproxy.cfg correcta."
        else
            echo -e "${RED}[ERROR]${NC} Error de sintaxis en $cfg_file"
            echo -e "${CYAN}[TIP]${NC} Depurar con: ${MAGENTA}haproxy -c -f $cfg_file${NC}\n"
            log_failure "Error sintaxis haproxy"
        fi
    fi

    # 3. Verificación del Servicio
    if systemctl is-active --quiet haproxy; then
        echo -e "${GREEN}[OK]${NC} Servicio HAProxy corriendo."
        log_success "HAProxy activo"
    else
        echo -e "${YELLOW}[AUTO-FIX]${NC} El servicio HAProxy está inactivo. Intentando arrancar..."
        if sudo systemctl enable --now haproxy &>/dev/null; then
            echo -e "${GREEN}[OK]${NC} Servicio HAProxy iniciado exitosamente."
            log_success "HAProxy activo (Auto-Fix)"
        else
            echo -e "${RED}[ERROR]${NC} El servicio HAProxy no pudo iniciarse."
            echo -e "${CYAN}[TIP]${NC} Revisa logs con: ${MAGENTA}journalctl -xeu haproxy${NC}\n"
            log_failure "Servicio HAProxy falló al iniciar"
        fi
    fi

    ((total_checks++))

    # --- Keepalived: solo necesario si hay más de un balanceador ---
    if [[ $(count_balancers) -gt 1 ]]; then
        echo ""
        echo -e "${YELLOW}--- Instalación de Keepalived (Alta Disponibilidad) ---${NC}"
        log "Detectados $(count_balancers) balanceadores. Keepalived es requerido para la VIP."

        # 1. Instalar keepalived si no está instalado
        if ! rpm -q keepalived &>/dev/null; then
            echo -e "${CYAN}[INFO]${NC} Instalando keepalived..."
            local install_cmd_keepalived="dnf install -y keepalived"
            echo -e "  ${MAGENTA}${install_cmd_keepalived}${NC}\n"
            if ! ${install_cmd_keepalived}; then
                echo -e "${RED}[ERROR]${NC} Falló la instalación de keepalived."
                log_failure "Error instalando keepalived"
                ((total_checks++))
                return
            fi
        else
            local keepalived_version
            keepalived_version=$(keepalived --version 2>&1 | head -n 1 | awk '{print $2}')
            echo -e "${GREEN}[OK]${NC} keepalived ya instalado: versión ${CYAN}${keepalived_version}${NC}"
        fi

        # 2. Habilitar keepalived (sin arrancar: requiere configuración previa)
        systemctl enable keepalived &>/dev/null
        if ! systemctl is-active --quiet keepalived; then
            echo -e "${YELLOW}[WARN]${NC} Servicio keepalived no está activo (esperado: requiere configuración antes de arrancar)."
            echo -e "${CYAN}[INFO]${NC} Se habilitará automáticamente una vez que se configure keepalived.conf con la VIP."
        else
            echo -e "${GREEN}[OK]${NC} Servicio keepalived activo."
        fi

        # Mostrar VIP ya configurada (fue recolectada en collect_virtual_ip)
        local saved_vip=""
        saved_vip=$(grep "^VIRTUAL_IP_ADDRESS=" "${K8S_VARIABLES}" 2>/dev/null | cut -d= -f2)
        if [[ -n "$saved_vip" ]]; then
            echo -e "${GREEN}[OK]${NC} VIRTUAL_IP_ADDRESS=${CYAN}${saved_vip}${NC} (configurada previamente)"
        else
            echo -e "${YELLOW}[WARN]${NC} VIRTUAL_IP_ADDRESS no encontrada en ${K8S_VARIABLES}."
        fi
        log_success "Keepalived instalado y habilitado"

        ((total_checks++))
    fi
}

function validate_repos_kubernetes() {
    # 1. Check Caché: si ya pasó antes, se salta todo
    if check_cache "validate_repos_kubernetes"; then return; fi


    echo -e "${YELLOW}--- Validación y estandarización de repositorios para Kubernetes/Docker ---${NC}"
    log "Verificando y normalizando repositorios de Kubernetes y Docker..."

    local missing_repos=()
    local network_advice=""
    local k8s_target_version="${KUBERNETES_VERSION}"
    
    local docker_repo_file="/etc/yum.repos.d/docker-ce.repo"
    local k8s_repo_file="/etc/yum.repos.d/kubernetes.repo"

    # =========================================================
    # 1. DOCKER (Containerd)
    # =========================================================
    
    # A) RESPALDO (En el mismo directorio, cambiando extensión)
    if [[ -f "$docker_repo_file" ]]; then
        # Renombramos a docker-ce.repo.bkp (dnf ignora todo lo que no termine en .repo)
        local docker_bkp="${docker_repo_file}.bkp"
        echo -e "${YELLOW}[RESET]${NC} Respaldando repo Docker existente..."
        sudo mv -f "$docker_repo_file" "$docker_bkp"
        echo -e " -> Archivado en: ${CYAN}${docker_bkp}${NC}"
    fi

    # B) CREACIÓN
    echo -e "${CYAN}[CONFIG]${NC} Generando repositorio Docker..."
    {
        echo "[docker-ce-stable]"
        echo "name=Docker CE Stable - \$basearch"
        echo "baseurl=https://download.docker.com/linux/centos/9/\$basearch/stable"
        echo "enabled=1"
        echo "gpgcheck=1"
        echo "gpgkey=https://download.docker.com/linux/centos/gpg"
    } | sudo tee "${docker_repo_file}" > /dev/null

    # C) VALIDACIÓN ROBUSTA (Makecache + Check)
    echo -e "${CYAN}[INFO]${NC} Validando conexión Docker..."
    # Limpiamos caché específico para evitar errores de metadatos viejos
    sudo dnf clean dbcache --disablerepo="*" --enablerepo="docker-ce-stable" &>/dev/null
    
    if sudo dnf makecache --disablerepo="*" --enablerepo="docker-ce-stable" &>/dev/null; then
        echo -e "${GREEN}[OK]${NC} Repositorio Docker accesible."
    else
        local docker_baseurl
        docker_baseurl=$(grep -m1 "^baseurl" "$docker_repo_file" | cut -d= -f2 | tr -d ' ')
        echo -e "${RED}[ERROR]${NC} Fallo de conexión con Docker."
        missing_repos+=("Docker")
        network_advice+="\n   -> URL: ${MAGENTA}${docker_baseurl:-https://download.docker.com}${NC} (Puerto 443)"
    fi

    echo "-----------------------------------------------------------"

    # =========================================================
    # 2. KUBERNETES (v1.35)
    # =========================================================
    
    # A) RESPALDO
    if [[ -f "$k8s_repo_file" ]]; then
        local k8s_bkp="${k8s_repo_file}.bkp"
        echo -e "${YELLOW}[RESET]${NC} Respaldando repo Kubernetes existente..."
        sudo mv -f "$k8s_repo_file" "$k8s_bkp"
        echo -e " -> Archivado en: ${CYAN}${k8s_bkp}${NC}"
    fi
    
    # B) CREACIÓN
    echo -e "${CYAN}[CONFIG]${NC} Generando repositorio Kubernetes (${k8s_target_version})..."
    {
        echo "[kubernetes]"
        echo "name=Kubernetes"
        echo "baseurl=https://pkgs.k8s.io/core:/stable:/${k8s_target_version}/rpm/"
        echo "enabled=1"
        echo "gpgcheck=1"
        echo "gpgkey=https://pkgs.k8s.io/core:/stable:/${k8s_target_version}/rpm/repodata/repomd.xml.key"
        echo "exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni"
    } | sudo tee "${k8s_repo_file}" > /dev/null

    # C) VALIDACIÓN ROBUSTA (Makecache es la prueba de fuego)
    echo -e "${CYAN}[INFO]${NC} Validando conexión Kubernetes..."
    # Limpiamos caché específico
    sudo dnf clean dbcache --disablerepo="*" --enablerepo="kubernetes" &>/dev/null
    
    # Intentamos actualizar la metadata. Si esto pasa, HAY INTERNET y el repo es válido.
    if sudo dnf makecache --disablerepo="*" --enablerepo="kubernetes" &>/dev/null; then
        echo -e "${GREEN}[OK]${NC} Repositorio Kubernetes accesible."
    else
        local k8s_baseurl
        k8s_baseurl=$(grep -m1 "^baseurl" "$k8s_repo_file" | cut -d= -f2 | tr -d ' ')
        echo -e "${RED}[ERROR]${NC} Fallo de conexión con Kubernetes."
        missing_repos+=("Kubernetes")
        network_advice+="\n   -> URL: ${MAGENTA}${k8s_baseurl:-https://pkgs.k8s.io}${NC} (Puerto 443)"
    fi

    # =========================================================
    # 3. VEREDICTO FINAL
    # =========================================================

    if [[ -n "$network_advice" ]]; then
        echo -e "\n${YELLOW}======================================================${NC}"
        echo -e "${YELLOW} 🛑 REQUISITO DE RED DETECTADO${NC}"
        echo -e "${YELLOW}======================================================${NC}"
        echo -e "El servidor no alcanza los repositorios necesarios:${network_advice}"
        echo -e "\n${CYAN}[NOTA]${NC} Si no hay internet, solicita acceso a esas URLs.\n"
        
        log_failure "Fallo crítico de repositorios: ${missing_repos[*]}"
        return
    elif [[ ${#missing_repos[@]} -eq 0 ]]; then
        log_success "Repositorios estandarizados y validados."
        mark_success "validate_repos_kubernetes"
    else
        log_failure "Errores desconocidos en repositorios."
    fi

    ((total_checks++))
}

function validate_container_runtime() {

    local check_name="validate_container_runtime"

    # =====================
    # CACHE
    # =====================
    if check_cache "${check_name}"; then
        return 0
    fi

    echo -e "${YELLOW}--- Validación de Runtime de Contenedores (containerd) ---${NC}"
    log "Verificando instalación, configuración y servicio de containerd..."

    # =====================
    # 1. VERIFICACIÓN DE PAQUETES
    # =====================
    local missing_pkgs=()

    # Binario principal
    if ! command -v containerd &>/dev/null; then
        missing_pkgs+=("containerd.io")
    fi

    # Dependencias críticas para Kubernetes
    if ! rpm -q socat &>/dev/null; then
        missing_pkgs+=("socat")
    fi

    if ! rpm -q conntrack-tools &>/dev/null; then
        missing_pkgs+=("conntrack-tools")
    fi

    # =====================
    # 1.A AUTOFIX DE PAQUETES
    # =====================
    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        echo -e "${RED}[ERROR]${NC} Faltan paquetes del runtime: ${missing_pkgs[*]}"
        echo -e "\n${CYAN}[ACCION AUTOMATICA]${NC} Instalando paquetes requeridos..."
        echo "-------------------------------------------------------------"
        echo -e "${MAGENTA}sudo dnf install -y ${missing_pkgs[*]} --allowerasing${NC}"
        echo "-------------------------------------------------------------"

        if sudo dnf install -y ${missing_pkgs[*]} --allowerasing; then
            echo -e "${GREEN}[OK]${NC} Paquetes instalados correctamente."
        else
            log_failure "Falló la instalación de paquetes del runtime: ${missing_pkgs[*]}"
        fi
    else
        echo -e "${GREEN}[OK]${NC} Paquetes containerd y dependencias ya instalados."
    fi

    # =====================
    # 2. VERIFICACIÓN + AUTOFIX DE CONFIGURACIÓN
    # =====================
    local cfg_file="/etc/containerd/config.toml"
    local need_fix=0

    # Validaciones mínimas (NO duplicamos Calico / sysctl / módulos)
    if [[ ! -f "$cfg_file" ]]; then
        echo -e "${YELLOW}[AUTO-FIX]${NC} ${cfg_file} no existe."
        need_fix=1
    elif ! grep -q "SystemdCgroup = true" "$cfg_file"; then
        echo -e "${YELLOW}[AUTO-FIX]${NC} SystemdCgroup no está habilitado."
        need_fix=1
    fi

    if ! systemctl is-active --quiet containerd; then
        echo -e "${YELLOW}[AUTO-FIX]${NC} Servicio containerd no está activo."
        need_fix=1
    fi

    # =====================
    # 2.A AUTOFIX DETERMINÍSTICO
    # =====================
    if [[ $need_fix -eq 1 ]]; then
        echo -e "\n${CYAN}[ACCION AUTOMATICA]${NC} Reconfigurando containerd desde cero..."
        echo "-------------------------------------------------------------"

        if containerd config default | sudo tee "$cfg_file" >/dev/null \
        && sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' "$cfg_file" \
        && sudo systemctl daemon-reload \
        && sudo systemctl restart containerd \
        && sudo systemctl enable containerd; then
            echo -e "${GREEN}[OK]${NC} containerd reconfigurado y servicio activo."
        else
            echo -e "${RED}[ERROR]${NC} Falló la reconfiguración automática de containerd."
            echo -e "${CYAN}[SOLUCIÓN MANUAL]${NC}"
            echo -e "${MAGENTA}containerd config default | sudo tee /etc/containerd/config.toml${NC}"
            echo -e "${MAGENTA}sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml${NC}"
            echo -e "${MAGENTA}sudo systemctl restart containerd${NC}"
            log_failure "No se pudo auto-configurar containerd"
        fi
    fi

    # =====================
    # 3. REVALIDACIÓN FINAL (AUTORITATIVA)
    # =====================
    if [[ ! -f "$cfg_file" ]]; then
        log_failure "Archivo config.toml de containerd no existe tras auto-fix"
    elif ! grep -q "SystemdCgroup = true" "$cfg_file"; then
        log_failure "SystemdCgroup sigue deshabilitado tras auto-fix"
    fi

    if ! systemctl is-active --quiet containerd; then
        log_failure "Servicio containerd no activo tras auto-fix"
    fi

    echo -e "${GREEN}[OK]${NC} containerd instalado, configurado y operativo."

    # =====================
    # 4. CONFIGURACIÓN DE CRICTL (NO DUPLICA VALIDACIONES)
    # =====================
    configure_crictl

    # =====================
    # 5. REGISTRO FINAL
    # =====================
    log_success "Runtime containerd validado y operativo"
    mark_success "${check_name}"
    ((total_checks++))
}

function configure_crictl() {
    local check_name="configure_crictl"

    # Cache
    if check_cache "${check_name}"; then
        return 0
    fi

    echo -e "${CYAN}[INFO]${NC} Configurando crictl para usar containerd..."

    # Si ya existe, no tocamos nada
    if [[ -f /etc/crictl.yaml ]]; then
        echo -e "${GREEN}[OK]${NC} /etc/crictl.yaml ya existe."
        log_success "crictl ya configurado"
        mark_success "${check_name}"
        ((total_checks++))
        return 0
    fi

    # Crear archivo usando printf (sin heredoc)
    if printf '%s\n' \
        "runtime-endpoint: unix:///run/containerd/containerd.sock" \
        "image-endpoint: unix:///run/containerd/containerd.sock" \
        "timeout: 10" \
        "debug: false" \
        | sudo tee /etc/crictl.yaml > /dev/null
    then
        echo -e "${GREEN}[OK]${NC} Archivo /etc/crictl.yaml creado correctamente."
        log_success "crictl configurado correctamente"
        mark_success "${check_name}"
    else
        echo -e "${RED}[ERROR]${NC} Falló la creación de /etc/crictl.yaml"
        log_failure "No se pudo configurar crictl"
        return 1
    fi

    ((total_checks++))
}

function validate_cgroups_v2() {
    echo -e "${YELLOW}--- Validación de cgroups v2 ---${NC}"
    log "Verificando cgroups v2..."

    local cgroup_type
    cgroup_type=$(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo "desconocido")

    if [[ "$cgroup_type" == "cgroup2fs" ]]; then
        echo -e "${GREEN}[OK]${NC} cgroups v2 activo."
        log_success "validate_cgroups_v2"
    else
        echo -e "${YELLOW}[AUTO-FIX]${NC} El sistema usa cgroups v1 ($cgroup_type). Habilitando v2..."

        # Modificar GRUB
        sudo sed -i 's/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="systemd.unified_cgroup_hierarchy=1"/' /etc/default/grub

        # Regenerar GRUB (Intento genérico compatible con RHEL/Oracle)
        if [[ -f /boot/grub2/grub.cfg ]]; then
            sudo grub2-mkconfig -o /boot/grub2/grub.cfg &>/dev/null
        elif [[ -f /boot/efi/EFI/oracle/grub.cfg ]]; then
            sudo grub2-mkconfig -o /boot/efi/EFI/oracle/grub.cfg &>/dev/null
        elif [[ -f /boot/efi/EFI/redhat/grub.cfg ]]; then
            sudo grub2-mkconfig -o /boot/efi/EFI/redhat/grub.cfg &>/dev/null
        else
            # Fallback
            sudo grub2-mkconfig -o /boot/grub2/grub.cfg &>/dev/null
        fi

        echo -e "${GREEN}[OK]${NC} Configuración de GRUB actualizada."
        declare -g PENDING_REBOOT=1
        log_success "cgroups v2 habilitado (Pendiente Reinicio)"
    fi
}

function validate_kubelet() {
    echo -e "${YELLOW}--- Validación de kubelet ---${NC}"
    log "Validando kubelet (instalación, servicio y cgroupDriver)..."

    # 1. Kubelet instalado
    if ! command -v kubelet &>/dev/null; then
        echo -e "${YELLOW}[AUTO-FIX]${NC} kubelet no está instalado. Instalando componentes de Kubernetes..."

        echo -e "${CYAN}[COMANDO]${NC} sudo dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes"
        if ! sudo dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes; then
            FAILED_CHECKS+=("validate_kubelet - fallo instalación kubelet/kubeadm/kubectl")
            log_failure "validate_kubelet - fallo instalando paquetes Kubernetes"
            ((total_checks++))
            return
        fi

        echo -e "${CYAN}[COMANDO]${NC} sudo systemctl enable --now kubelet"
        if ! sudo systemctl enable --now kubelet; then
            FAILED_CHECKS+=("validate_kubelet - kubelet no pudo iniciarse")
            log_failure "validate_kubelet - kubelet instalado pero no inicia"
            ((total_checks++))
            return
        fi

        echo -e "${GREEN}[OK]${NC} kubelet instalado y servicio activo"
    fi

    # 2. Servicio habilitado
    if systemctl is-enabled kubelet &>/dev/null; then
        echo -e "${GREEN}[OK]${NC} Servicio kubelet está habilitado en systemd."
    else
        echo -e "${YELLOW}[AUTO-FIX]${NC} Servicio kubelet no está habilitado. Habilitando..."
        if sudo systemctl enable kubelet &>/dev/null; then
            echo -e "${GREEN}[OK]${NC} Servicio kubelet habilitado exitosamente."
        else
            echo -e "${RED}[ERROR]${NC} Falló al habilitar el servicio kubelet."
            log_failure "validate_kubelet - fallo al habilitar kubelet"
            FAILED_CHECKS+=("validate_kubelet - kubelet no pudo habilitarse")
            ((total_checks++))
            return
        fi
    fi

    # 3. Servicio activo
    if systemctl is-active kubelet &>/dev/null; then
        echo -e "${GREEN}[OK]${NC} Servicio kubelet está activo."
    else
        echo -e "${YELLOW}[WARN]${NC} kubelet está instalado y habilitado, pero no activo."
        echo -e "${CYAN}[SOLUCIÓN]${NC} Es común que kubelet no arranque hasta ejecutar:"
        echo -e " - En MANAGER: ${MAGENTA}kubeadm init ...${NC}"
        echo -e " - En WORKER : ${MAGENTA}kubeadm join ...${NC}"
        echo -e "${CYAN}[TIP]${NC} Revisa logs con: ${MAGENTA}journalctl -xeu kubelet${NC}"
        
        # En lugar de fallar, marcamos como éxito con una nota informativa
        echo -e "${GREEN}[OK (CONDICIONAL)]${NC} Kubelet está instalado. Se iniciará automáticamente tras el 'kubeadm init/join'."
        
        # Registramos éxito para que no cuente como error en el resumen final
        log_success "Kubelet instalado (Estado inactivo es normal en esta etapa)"
fi

    # 4. Validar alineación del cgroupDriver (cuando haya config de kubeadm)
    #   - Kubernetes reciente recomienda driver systemd.[web:2][web:6]
    local kubelet_conf=""
    if [[ -f /var/lib/kubelet/config.yaml ]]; then
        kubelet_conf="/var/lib/kubelet/config.yaml"
    elif [[ -f /etc/kubernetes/kubelet-config.yaml ]]; then
        kubelet_conf="/etc/kubernetes/kubelet-config.yaml"
    fi

    local driver_msg=""
    if [[ -n "$kubelet_conf" ]]; then
        # Buscar línea cgroupDriver: en el YAML
        local k_driver
        k_driver=$(grep -E "^[[:space:]]*cgroupDriver:" "$kubelet_conf" 2>/dev/null | awk -F: '{gsub(/ /,"",$2); print $2}')

        if [[ -n "$k_driver" ]]; then
            echo -e "${CYAN}[INFO]${NC} cgroupDriver configurado en kubelet: ${MAGENTA}${k_driver}${NC}"
            driver_msg="$k_driver"
        else
            echo -e "${YELLOW}[WARN]${NC} No se encontró 'cgroupDriver' explícito en ${kubelet_conf}."
        fi
    else
        echo -e "${YELLOW}[WARN]${NC} No se encontró archivo de configuración de kubelet generado por kubeadm."
    fi

    # 5. Comparar con runtime (containerd) cuando sea posible
    #    - Si containerd usa SystemdCgroup=true, lo ideal es kubelet cgroupDriver=systemd.[web:2][web:6]
    local runtime_uses_systemd=false
    if grep -q "SystemdCgroup = true" /etc/containerd/config.toml 2>/dev/null; then
        runtime_uses_systemd=true
    fi

    if [[ "$runtime_uses_systemd" == true && -n "$driver_msg" && "$driver_msg" != "systemd" ]]; then
        echo -e "${RED}[ERROR]${NC} Desalineación detectada:"
        echo -e " - Runtime (containerd): usa ${MAGENTA}SystemdCgroup = true${NC}."
        echo -e " - kubelet cgroupDriver : ${MAGENTA}${driver_msg}${NC} (debería ser 'systemd')."
        echo -e "${CYAN}[SOLUCIÓN]${NC} Ajusta el cgroupDriver de kubelet a 'systemd' para evitar errores de arranque.[web:2][web:6]"
        echo -e " Si usas kubeadm, puedes definirlo en el ClusterConfiguration / KubeletConfiguration."
        echo -e " Ejemplo (fragmento YAML):"
        echo -e " kubeletConfiguration:"
        echo -e "   cgroupDriver: systemd\n"

        log_failure "validate_kubelet - mismatch cgroupDriver/kubelet vs containerd"
        FAILED_CHECKS+=("validate_kubelet - cgroupDriver != systemd con containerd SystemdCgroup=true")
    else
        echo -e "${GREEN}[OK]${NC} Configuración de kubelet compatible con el runtime de contenedores (en lo que se pudo detectar)."
        log_success "validate_kubelet"
    fi

    ((total_checks++))
}

function validate_k8s_control_plane() {
    echo -e "${YELLOW}--- Validación de herramientas de control Kubernetes ---${NC}"
    log "Verificando kubeadm y kubectl (Versión >= ${KUBERNETES_VERSION})..."

    local min_major=$(echo "${KUBERNETES_VERSION}" | sed 's/v//' | cut -d. -f1)
    local min_minor=$(echo "${KUBERNETES_VERSION}" | sed 's/v//' | cut -d. -f2)
    local tools=("kubeadm" "kubectl")
    local all_ok=true

    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            echo -e "${RED}[ERROR]${NC} ${tool} no está instalado."
            echo -e "${CYAN}[SOLUCIÓN]${NC} Ejecute:"
            echo -e "${MAGENTA}sudo dnf install -y ${tool}${NC}\n"
            FAILED_CHECKS+=("validate_k8s_control_plane - Falta ${tool}")
            all_ok=false
            log_failure "Falta herramienta ${tool}"
            continue
        fi

        # Extraer versión. Formato típico: "v1.31.1" -> "1.31"
        # kubeadm version: "kubeadm version: &version.Info{Major:\"1\", Minor:\"31\", ...}"
        # kubectl version: "Client Version: v1.31.1"
        local version_str=""
        if [[ "$tool" == "kubeadm" ]]; then
            version_str=$(kubeadm version -o short 2>/dev/null) # v1.34
        else
            version_str=$(kubectl version --client --output=json 2>/dev/null | jq -r '.clientVersion.gitVersion' 2>/dev/null) 
            [[ -z "$version_str" ]] && version_str=$(kubectl version --client --short 2>/dev/null | awk '{print $3}')
        fi

        # Limpiar "v" inicial si existe
        version_str="${version_str#v}"
        
        local major=$(echo "$version_str" | cut -d. -f1)
        local minor=$(echo "$version_str" | cut -d. -f2)

        echo -e "${GREEN}[OK]${NC} ${tool} detectado: Versión ${MAGENTA}${version_str}${NC}"

        # Validar >= v1.35
        # Comparamos: (Major > Req) O (Major == Req Y Minor >= Req)
        if (( major > min_major )) || { (( major == min_major )) && (( minor >= min_minor )); }; then
            echo -e "${GREEN}[OK]${NC} ${tool} cumple con la versión mínima (Actual: ${CYAN}${version_str}${NC})"
        else
            echo -e "${YELLOW}[WARN]${NC} La versión de ${tool} (${version_str}) es inferior a ${KUBERNETES_VERSION}."
            echo -e "${CYAN}[SOLUCIÓN]${NC} Se recomienda actualizar para garantizar soporte moderno."
            # No marcamos error fatal (all_ok=false), solo advertimos.
        
        fi
    done

    if [[ "$all_ok" == true ]]; then
        log_success "Herramientas de control plane verificadas."
    else
        log_failure "Faltan herramientas del control plane."
    fi

    ((total_checks++))
}

function validate_calico_prerequisites() {
    # 1. Check Caché
    if check_cache "validate_calico_prerequisites"; then return; fi

    echo -e "${YELLOW}--- Validación de Prerrequisitos de Red (Calico/K8s) ---${NC}"
    log "Verificando módulos del kernel y parámetros sysctl..."

    local all_ok=true

    # 1. VERIFICAR Y CARGAR MÓDULOS (Memoria + Persistencia)
    # -----------------------------------------------------
    local modules=("overlay" "br_netfilter")
    local modules_reloaded=false

    for mod in "${modules[@]}"; do
        if ! lsmod | grep -q "^$mod"; then
            echo -e "${YELLOW}[AUTO-FIX]${NC} Módulo '${mod}' no cargado. Cargando..."
            if sudo modprobe "$mod"; then
                echo -e "${GREEN}[OK]${NC} Módulo '${mod}' cargado exitosamente."
                modules_reloaded=true
            else
                echo -e "${RED}[ERROR]${NC} Falló la carga del módulo '${mod}'."
                all_ok=false
            fi
        else
            echo -e "${GREEN}[OK]${NC} Módulo '${mod}' ya estaba activo en memoria."
        fi
    done

    # Asegurar persistencia en /etc/modules-load.d/k8s.conf
    # Verificación de persistencia (si no existe el archivo O le falta el contenido)
    if [[ ! -f /etc/modules-load.d/k8s.conf ]] || ! grep -q "br_netfilter" /etc/modules-load.d/k8s.conf; then
        echo -e "${YELLOW}[AUTO-FIX]${NC} Generando persistencia de módulos en /etc/modules-load.d/k8s.conf..."
        
        {
            echo "overlay"
            echo "br_netfilter"
        } | sudo tee /etc/modules-load.d/k8s.conf >/dev/null
        
        echo -e "${GREEN}[OK]${NC} Archivo de persistencia creado/actualizado."
    fi

    # 2. VERIFICAR Y APLICAR SYSCTL (Puentes y Forwarding)
    # ----------------------------------------------------
    # Definimos el estado deseado
    declare -A sysctl_params=(
        ["net.bridge.bridge-nf-call-iptables"]="1"
        ["net.bridge.bridge-nf-call-ip6tables"]="1"
        ["net.ipv4.ip_forward"]="1"
    )

    local sysctl_reload_needed=false

    # Verificar archivo de configuración en disco
    if [[ ! -f /etc/sysctl.d/99-z-k8s.conf ]]; then
        echo -e "${YELLOW}[AUTO-FIX]${NC} Creando archivo /etc/sysctl.d/99-z-k8s.conf..."
        sysctl_reload_needed=true
    else
        # Si existe, verificamos si contiene las líneas clave
        for param in "${!sysctl_params[@]}"; do
            if ! grep -q "^$param" /etc/sysctl.d/99-z-k8s.conf; then
                sysctl_reload_needed=true
                break
            fi
        done
    fi

    if [[ "$sysctl_reload_needed" == "true" ]]; then
        echo -e "${YELLOW}[AUTO-FIX]${NC} Escribiendo parámetros sysctl requeridos..."
        
        {
            echo "# Permite a iptables ver tráfico de bridges (pods)"
            echo "net.bridge.bridge-nf-call-iptables  = 1"
            echo "net.bridge.bridge-nf-call-ip6tables = 1"
            echo "# Permite enrutar tráfico entre pods y nodos"
            echo "net.ipv4.ip_forward                 = 1"
            echo "# Evita problemas con conntrack en clusters"
            echo "net.netfilter.nf_conntrack_max = 1310720"
            echo "# Reduce problemas de conexiones NodePort / Services"
            echo "net.ipv4.conf.all.rp_filter = 0"
            echo "net.ipv4.conf.default.rp_filter = 0"
        } | sudo tee /etc/sysctl.d/99-z-k8s.conf >/dev/null

        echo -e "${CYAN}[INFO]${NC} Aplicando cambios con 'sysctl --system'..."
        sudo sysctl --system >/dev/null 2>&1

    elif [[ "$modules_reloaded" == "true" ]]; then
        # Si cargamos módulos recién ahora, hay que reaplicar sysctl para que net.bridge exista
        echo -e "${CYAN}[INFO]${NC} Módulos recargados. Re-aplicando sysctl..."
        sudo sysctl --system >/dev/null 2>&1
    fi

    # 3. PROTECCIÓN RUNTIME: systemd unit para re-forzar ip_forward
    # -------------------------------------------------------------
    local unit_file="/etc/systemd/system/fix-ip-forward.service"

    if [[ ! -f "$unit_file" ]]; then
        echo -e "${YELLOW}[AUTO-FIX]${NC} Creando servicio systemd para proteger net.ipv4.ip_forward..."

        sudo tee "$unit_file" >/dev/null <<'EOF'
[Unit]
Description=Force net.ipv4.ip_forward=1 after network services
After=network.target NetworkManager.service
Wants=network.target

[Service]
Type=oneshot
ExecStart=/sbin/sysctl -w net.ipv4.ip_forward=1
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

        sudo systemctl daemon-reload
        sudo systemctl enable --now fix-ip-forward.service >/dev/null 2>&1
        echo -e "${GREEN}[OK]${NC} Servicio fix-ip-forward.service habilitado."
    else
        echo -e "${GREEN}[OK]${NC} Servicio fix-ip-forward.service ya existe."
    fi

    # 4. VERIFICACIÓN FINAL (Lectura de valores activos)
    # --------------------------------------------------
    echo -e "${CYAN}[INFO]${NC} Verificando valores activos en el kernel..."
    
    for param in "${!sysctl_params[@]}"; do
        local expected="${sysctl_params[$param]}"
        # Leemos el valor real del kernel
        local current
        current=$(sysctl -n "$param" 2>/dev/null)

        if [[ "$current" == "$expected" ]]; then
            echo -e "${GREEN}[OK]${NC} $param = $current"
        else
            echo -e "${RED}[ERROR]${NC} $param = ${current:-VACÍO} (Esperado: $expected)"
            # Diagnóstico específico
            if [[ "$param" == *"bridge"* && -z "$current" ]]; then
                echo -e "${YELLOW}[DIAGNÓSTICO]${NC} La variable no existe. Probablemente br_netfilter falló al cargar."
            fi
            all_ok=false
        fi
    done

    # 4. EXCEPCIÓN NETWORK MANAGER (Solo si existe nmcli/NetworkManager)
    # ------------------------------------------------------------------
    if systemctl is-active --quiet NetworkManager; then
        local nm_conf="/etc/NetworkManager/conf.d/calico.conf"
        if [[ ! -f "$nm_conf" ]]; then
            echo -e "${YELLOW}[AUTO-FIX]${NC} Configurando NetworkManager para ignorar interfaces Calico..."
            echo -e '[keyfile]\nunmanaged-devices=interface-name:cali*;interface-name:tunl*' | sudo tee "$nm_conf" >/dev/null
            sudo systemctl reload NetworkManager
            echo -e "${GREEN}[OK]${NC} Excepción de NetworkManager aplicada."
        else
            echo -e "${GREEN}[OK]${NC} NetworkManager ya ignora interfaces Calico."
        fi
    fi

    # RESULTADO FINAL
    if [[ "$all_ok" == "true" ]]; then
        log_success "Prerrequisitos de red (Calico) configurados y validados."
    else
        log_failure "Falló la configuración de red para Calico."
        FAILED_CHECKS+=("validate_calico_prerequisites - error en módulos o sysctl")
    fi

    mark_success "validate_calico_prerequisites"
    ((total_checks++))
}

function validate_wss_worker() {
    # 1. Verificación de Caché (Estado)
    # Si existe validate_wss_worker.ok en la carpeta state, salta la función
    if check_cache "validate_wss_worker"; then return; fi

    echo -e "${YELLOW}--- Optimización Específica WSS (Protocolo WebSocket) ---${NC}"
    log "Ajustando límites de File Descriptors y Stack TCP para Workers..."

    # 2. Límites de Descriptores de Archivos (Ulimit / NOFILE)
    # Esto permite que un solo proceso maneje más de 1 millón de conexiones
    cat <<EOF | sudo tee /etc/security/limits.d/99-zzz-wss-limits.conf >/dev/null
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

    sudo mkdir -p /etc/systemd/system.conf.d
    echo -e "[Manager]\nDefaultLimitNOFILE=1048576" | sudo tee /etc/systemd/system.conf.d/99-zzz-wss-systemd.conf >/dev/null

    # 3. Optimización de Kernel (Sysctl)
    # Usamos "99-zzz" para que se procese después de los archivos de Kubernetes
    # Mantenemos nf_conntrack_max en 1310720 (el valor más alto para no malograr K8s)
    cat <<EOF | sudo tee /etc/sysctl.d/99-zzz-wss-custom.conf >/dev/null
# TCP Keepalive para evitar cortes en conexiones persistentes
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 4

# Gestión de Conexiones y Puertos
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1

# Buffers de memoria para alta demanda
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864

# Conntrack optimizado para Calico + WSS
net.netfilter.nf_conntrack_max = 1310720
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
EOF

    # Aplicar los cambios de sysctl inmediatamente
    sudo sysctl --system >/dev/null 2>&1

    # 4. Finalización y Marcado de Éxito
    # Crea el archivo .ok para que no se vuelva a ejecutar
    mark_success "validate_wss_worker"
    log_success "Optimización WSS aplicada y registrada en el estado."
    ((total_checks++))
}

function validate_mount_flags_local_storage() {
    echo -e "${YELLOW}--- Validación de Montajes para Almacenamiento Local ---${NC}"
    log "Analizando flags de montaje para compatibilidad con local-path-storage..."

    local paths=(
        "/opt/local-path-provisioner"
        "/var/lib/local-storage"
        "/var/lib/kubelet"
        "/var/lib/containerd"
    )
    
    local critical_flags=("noexec" "ro" "tmpfs")
    local warning_flags=("nosuid" "nodev" "noatime")
    local found_critical=false

    for path in "${paths[@]}"; do
        echo -e "\n${CYAN}[RUTA]${NC} ${path}"
        
        # 1. Asegurar existencia para /opt/local-path-provisioner (Enterprise requirement)
        if [[ "$path" == "/opt/local-path-provisioner" ]]; then
            if [[ ! -d "$path" ]]; then
                echo -e "${YELLOW}[AUTO-FIX]${NC} Directorio no existe. Creando..."
                sudo mkdir -p "$path"
                echo -e "${GREEN}[OK]${NC} Directorio creado con éxito."
            fi
        else
            if [[ ! -d "$path" ]]; then
                echo -e "${YELLOW}[INFO]${NC} Directorio no existe actualmente (será gestionado por K8s/Runtime)."
                continue
            fi
        fi

        # 2. Obtener información de montaje usando findmnt (Estándar RHEL 8/9)
        local mount_info
        mount_info=$(findmnt -n -o SOURCE,FSTYPE,OPTIONS -T "$path" 2>/dev/null)
        
        if [[ -z "$mount_info" ]]; then
            echo -e "${GREEN}[OK]${NC} La ruta reside en el filesystem raíz (/). Sin restricciones específicas de montaje."
            continue
        fi

        local dev=$(echo "$mount_info" | awk '{print $1}')
        local fs=$(echo "$mount_info" | awk '{print $2}')
        local opts=$(echo "$mount_info" | awk '{print $3}')

        echo -e "  Filesystem: ${MAGENTA}${fs}${NC} (${dev})"
        echo -e "  Opciones  : ${opts}"

        # 3. Validar Flags Críticos
        for flag in "${critical_flags[@]}"; do
            if [[ ",$opts," == *",$flag,"* ]] || [[ "$fs" == "tmpfs" && "$flag" == "tmpfs" ]]; then
                echo -e "  ${RED}🛑 ALERTA CRÍTICA:${NC} Se detectó flag '${RED}${flag}${NC}' incompatible."
                found_critical=true
            fi
        done

        # 4. Validar Flags Warning
        for flag in "${warning_flags[@]}"; do
            if [[ ",$opts," == *",$flag,"* ]]; then
                echo -e "  ${YELLOW}⚠️  ADVERTENCIA:${NC} Flag '${flag}' detectado (informativo)."
            fi
        done
        
        # 5. Espacio disponible (Informativo para el administrador)
        local space_avail
        space_avail=$(df -h "$path" 2>/dev/null | awk 'NR==2 {print $4}')
        echo -e "  Espacio disponible: ${GREEN}${space_avail:-Desconocido}${NC}"
    done

    if [[ "$found_critical" == true ]]; then
        echo -e "\n${RED}╔════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║ 🛑 ATENCIÓN: RESTRICCIONES DE MONTAJE DETECTADAS                     ║${NC}"
        echo -e "${RED}╠════════════════════════════════════════════════════════════════════════╣${NC}"
        echo -e "${RED}║${NC} ${YELLOW}Se han detectado opciones de montaje (noexec, ro o tmpfs) que${NC}      ${RED}║${NC}"
        echo -e "${RED}║${NC} ${YELLOW}afectan la persistencia o ejecución en este nodo.${NC}                  ${RED}║${NC}"
        echo -e "${RED}║${NC} ${CYAN}IMPACTO:${NC} Los Pods podrían fallar al intentar ejecutar binarios o  ${RED}║${NC}"
        echo -e "${RED}║${NC} los datos podrían ser volátiles tras un reinicio del sistema.    ${RED}║${NC}"
        echo -e "${RED}║${NC} ${MAGENTA}ACCIÓN:${NC} Por favor, solicite al administrador de SO revisar el       ${RED}║${NC}"
        echo -e "${RED}║${NC} montaje de estas particiones en /etc/fstab para el cluster K8s.  ${RED}║${NC}"
        echo -e "${RED}╚════════════════════════════════════════════════════════════════════════╝${NC}"
        echo
        pause_prompt "Presione ENTER para confirmar la lectura de esta alerta técnica y continuar..."
    fi

    log_success "Validación de almacenamiento local finalizada"
}

function count_balancers() {
    grep -c "^BALANCEADOR," "$K8S_INVENTORY" 2>/dev/null || echo 0
}

function collect_virtual_ip() {
    [[ $(count_balancers) -le 1 ]] && return

    echo -e "\n${YELLOW}--- Configuración de IP Virtual (Keepalived / Alta Disponibilidad) ---${NC}"

    # Mostrar valor actual si ya existe
    local current_vip=""
    local change_vip=""
    if grep -q "^VIRTUAL_IP_ADDRESS=" "${K8S_VARIABLES}" 2>/dev/null; then
        current_vip=$(grep "^VIRTUAL_IP_ADDRESS=" "${K8S_VARIABLES}" | cut -d= -f2)
        echo -e "${CYAN}[INFO]${NC} VIRTUAL_IP_ADDRESS actual: ${MAGENTA}${current_vip}${NC}"
        read_with_default change_vip "¿Desea cambiarla? (s/N): " "n"
        [[ ! "$change_vip" =~ ^[Ss]$ ]] && return
    fi

    local vip_input=""
    while true; do
        if ! read_with_default vip_input "Ingrese VIRTUAL_IP_ADDRESS (ej: 192.168.18.200): " ""; then
            log_failure "No se puede capturar VIRTUAL_IP_ADDRESS sin TTY. Defínala en ${K8S_VARIABLES} y reintente."
        fi
        if [[ "$vip_input" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            break
        else
            echo -e "${RED}[ERROR]${NC} Formato inválido. Ingrese una IP válida (ej: 192.168.18.200)."
        fi
    done

    if grep -q "^VIRTUAL_IP_ADDRESS=" "${K8S_VARIABLES}" 2>/dev/null; then
        sed -i "s|^VIRTUAL_IP_ADDRESS=.*|VIRTUAL_IP_ADDRESS=${vip_input}|" "${K8S_VARIABLES}"
    else
        echo "VIRTUAL_IP_ADDRESS=${vip_input}" >> "${K8S_VARIABLES}"
    fi

    echo -e "${GREEN}[OK]${NC} VIRTUAL_IP_ADDRESS=${CYAN}${vip_input}${NC} guardado en ${K8S_VARIABLES}"
    log_success "VIRTUAL_IP_ADDRESS configurada: ${vip_input}"
}

function detect_role() {
    log "Detectando rol del servidor..."
    local current_hostname=$(hostname)
    local current_ips=$(hostname -I)

    ROLE=""
    ROLE_IP=""
    ROLE_HOSTNAME=""

    # CAMBIO: Se agrega role_order a la lectura
    while IFS=',' read -r rol role_order hostname ip; do
        [[ "$rol" =~ ^#.*$ || -z "$rol" || -z "$role_order" || -z "$hostname" || -z "$ip" ]] && continue

        if [[ "${hostname,,}" == "${current_hostname,,}" ]]; then
            ROLE="$rol"
            ROLE_HOSTNAME="$hostname"
            ROLE_IP="$ip"

            if echo "$current_ips" | grep -qw "$ip"; then
                log_success "Rol detectado correctamente: ${CYAN}$ROLE${NC}"
                echo -e "${CYAN}[INFO]${NC} Hostname: $ROLE_HOSTNAME"
                echo -e "${CYAN}[INFO]${NC} IP configurada: $ROLE_IP"
                return 0
            else
                log_failure "La IP configurada ($ip) en ${YELLOW}${K8S_INVENTORY}${NC} no coincide con ninguna IP actual"
                echo -e "${CYAN}[INFO]${NC} IPs actuales: $current_ips"
                exit 1
            fi
        fi
    done < "$K8S_INVENTORY"

    log_failure "No se encontró coincidencia del hostname '${current_hostname}' en ${YELLOW}${K8S_INVENTORY}${NC}"
    exit 1
}

function validate_commons_by_role() {
    echo -e "\n${YELLOW}=== INICIANDO VALIDACIONES PARA ROL: ${MAGENTA}$ROLE${YELLOW} ===${NC}"
    
    case "$ROLE" in
        BALANCEADOR)
            validate_repos_balancer
            validate_haproxy
            ;;
        MANAGER)
            validate_repos_kubernetes        # 1. Repos (Docker + K8s)
            validate_container_runtime       # 2. Runtime (Usa repo Docker)
            validate_cgroups_v2              # 3. Kernel/Cgroups
            validate_kubelet                 # 4. Kubelet (Usa repo K8s)
            validate_k8s_control_plane       # 5. Herramientas Control Plane
            validate_calico_prerequisites    # 6. Red
            validate_mount_flags_local_storage # 7. Storage Local
            ;;
        WORKER)
            validate_repos_kubernetes        # 1. Repos
            validate_container_runtime       # 2. Runtime
            validate_cgroups_v2              # 3. Kernel/Cgroups
            validate_kubelet                 # 4. Kubelet
            validate_calico_prerequisites    # 5. Red
            validate_mount_flags_local_storage # 6. Storage Local
            validate_wss_worker              # 7. WSS
            ;;
    esac

    echo -e "${YELLOW}=== VALIDACIONES ESPECÍFICAS COMPLETADAS ===${NC}"
}

function show_summary() {
    local total=$((passed_checks + failed_checks))
    local success_percent=0
    local failed_percent=0

    if [[ $total -gt 0 ]]; then
        success_percent=$(echo "scale=2; $passed_checks * 100 / $total" | bc)
        failed_percent=$(echo "scale=2; $failed_checks * 100 / $total" | bc)
    fi
    
    echo -e "\n${CYAN}========== RESUMEN DETALLADO ==========${NC}"
    echo -e "Total de verificaciones: ${total}"
    echo -e "${GREEN}✅ Correctas: ${passed_checks} (${success_percent}%)${NC}"

    if [[ $failed_checks -gt 0 ]]; then
        echo -e "${RED}❌ Fallidas: ${failed_checks} (${failed_percent}%)${NC}"
        echo -e "\n${RED}🛑 Se encontraron errores bloqueantes.${NC}"
        echo -e "Revisa la lista de fallos arriba y vuelve a ejecutar el script."
        exit 1
    else
        echo -e "${GREEN}❌ Fallidas: 0 (0%)${NC}"
        echo -e "\n${GREEN}✔ Todo listo! El servidor cumple los prerequisitos.${NC}"
        
        # --- MENSAJE COMPACTO Y LIMPIO ---
        echo -e "\n${YELLOW}╔══════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║  ⚠️  ACCIÓN REQUERIDA: CARGAR VARIABLES               ║${NC}"
        echo -e "${YELLOW}╠══════════════════════════════════════════════════════╣${NC}"
        echo -e "${YELLOW}║${NC} ${CYAN}Se generaron nuevas variables de entorno.${NC}            ${YELLOW}║${NC}"
        echo -e "${YELLOW}║${NC} ${CYAN}Para aplicarlas en esta sesión, ejecuta:${NC}             ${YELLOW}║${NC}"
        echo -e "${YELLOW}║${NC}   ${MAGENTA}source ${K8S_VARIABLES}${NC}                    ${YELLOW}║${NC}"
        echo -e "${YELLOW}╚══════════════════════════════════════════════════════╝${NC}\n"
    fi
}

# =====================
# EJECUCIÓN
# =====================
validate_inventory
show_header
detect_os
validate_all_hosts
collect_virtual_ip
validate_commons_by_role

# === VERIFICACIÓN DE REINICIO PENDIENTE ===
if [[ "$PENDING_REBOOT" -eq 1 ]]; then
    echo -e "\n${RED}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║ 🛑 REINICIO REQUERIDO PARA APLICAR CAMBIOS           ║${NC}"
    echo -e "${RED}╠══════════════════════════════════════════════════════╣${NC}"
    echo -e "${RED}║${NC} ${YELLOW}Se han corregido configuraciones de Kernel/Sistema.${NC}  ${RED}║${NC}"
    echo -e "${RED}║${NC} ${YELLOW}(SELinux / Swap / Cgroups)${NC}                           ${RED}║${NC}"
    echo -e "${RED}║${NC} ${CYAN}El script ha continuado para avanzar, pero DEBES${NC}     ${RED}║${NC}"
    echo -e "${RED}║${NC} ${CYAN}reiniciar ahora para finalizar la preparación.${NC}       ${RED}║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════╝${NC}"

    # Preguntar al usuario si quiere reiniciar ya
    echo
    read_with_default REPLY "¿Desea reiniciar el servidor ahora? (s/n): " "n"
    if [[ "$REPLY" =~ ^[Ss]$ ]]; then
        echo "Reiniciando..."
        sudo reboot
    else
        echo -e "${YELLOW}[WARN]${NC} No olvides reiniciar antes de instalar Kubernetes."
    fi
    exit 0
fi

show_summary
