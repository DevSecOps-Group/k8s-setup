#!/usr/bin/env bash
# =============================================================================
# 03-teardown-servers.sh
# Kubernetes HA - Cluster Teardown & Server Reset for Network Migration
# Autor    : Ing. Jesús A. Chávez Becerra
# Compañía : DevSecOps Group S.A.C.
# Cargo    : DevSecOps, Cloud and Infrastructure Architect
# Proyecto : KUBERNETES HA ON-PREMISE (Ambiente Pre-productivo)
# Uso      : ./03-teardown-servers.sh [--force]
# Propósito: Revertir el clúster K8s/HAProxy/Keepalived por completo,
#            conservando paquetes, binarios e imágenes para una futura
#            reinstalación limpia con 01-setup-k8s-pre-reqs.sh
# =============================================================================

# NOTA: se usa set -uo (sin -e) para que los || true funcionen en subshells
# sin abortar el script. Las funciones críticas validan errores explícitamente.
set -uo pipefail

# ---------------------------------------------------------------------------
# 0. Rutas base (alineadas con cluster.env)
# ---------------------------------------------------------------------------
BASE_DIR="${K8S_BASE_DIR:-/root/k8s-installer}"
K8S_INVENTORY="${K8S_INVENTORY:-${BASE_DIR}/inventory.csv}"
LOG_FILE="${BASE_DIR}/08-teardown-servers-$(date +%Y%m%d_%H%M%S).log"

# ---------------------------------------------------------------------------
# 1. Colores ANSI
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; MAGENTA='\033[1;35m'; BOLD='\033[1m'; NC='\033[0m'

INTERACTIVE_TTY=false
[[ -t 0 && -t 1 ]] && INTERACTIVE_TTY=true
if [[ "$INTERACTIVE_TTY" != true || -n "${K8S_NO_COLOR:-}" ]]; then
    RED=''; GREEN=''; YELLOW=''; CYAN=''; MAGENTA=''; BOLD=''; NC=''
fi

# ---------------------------------------------------------------------------
# 2. Logging con tee al archivo
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

log_info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "\n${MAGENTA}${BOLD}━━━ $* ━━━${NC}"; }

# ---------------------------------------------------------------------------
# 3. Detección de rol desde inventory.csv
# ---------------------------------------------------------------------------
detect_role() {
    if [[ ! -f "$K8S_INVENTORY" ]]; then
        log_err "Inventario no encontrado: $K8S_INVENTORY"
        exit 1
    fi
    local hn; hn=$(hostname)
    local role
    role=$(awk -F',' -v h="$hn" 'tolower($3)==tolower(h) {print $1; exit}' "$K8S_INVENTORY" 2>/dev/null || true)
    if [[ -z "$role" ]]; then
        log_err "Este hostname '${hn}' no figura en ${K8S_INVENTORY}"
        log_err "Verifique que el archivo exista y contenga la entrada correcta."
        exit 1
    fi
    echo "$role"
}

ROLE=$(detect_role)
# FORCE_MODE se lee de los argumentos del script (pasados desde main "$@")
# No se lee aquí directamente para evitar que $1 capture argumentos del entorno
FORCE_MODE=""

# ---------------------------------------------------------------------------
# 4. Cabecera
# ---------------------------------------------------------------------------
show_header() {
    local SEP="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "\n${CYAN}${SEP}${NC}"
    echo -e "  ${BOLD}${MAGENTA}KUBERNETES HA CLUSTER │ Server Reset for Network Migration (Pre-prod)${NC}"
    echo -e "${CYAN}${SEP}${NC}"
    echo -e "  ${BOLD}Nodo${NC}  : $(hostname)   ${BOLD}Rol${NC}: ${MAGENTA}${ROLE}${NC}   ${BOLD}IP${NC}: $(hostname -I | awk '{print $1}')"
    echo -e "  ${BOLD}Fecha${NC} : $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo -e "  ${BOLD}Log${NC}   : ${LOG_FILE}"
    echo -e "  ${BOLD}Autor${NC} : Ing. Jesús A. Chávez Becerra | DevSecOps Group S.A.C."
    echo -e "  ${BOLD}Cargo${NC} : DevSecOps, Cloud and Infrastructure Architect"
    echo -e "${CYAN}${SEP}${NC}\n"

    echo -e "${BOLD}ACCIONES A EJECUTAR PARA ROL '${ROLE}':${NC}"
    case "$ROLE" in
        MANAGER)
            echo -e "  • Limpiar namespaces Ingress Nginx / Storage (solo en primer MANAGER)"
            echo -e "  • kubeadm reset -f"
            echo -e "  • Eliminar /etc/cni, /etc/kubernetes, /var/lib/etcd, /var/lib/kubelet"
            echo -e "  • Eliminar /var/lib/dockershim, /var/run/kubernetes, ~/.kube/*"
            echo -e "  • Limpiar interfaces CNI, iptables (filter/nat/raw/mangle), IPVS"
            echo -e "  • Reiniciar servicios base: containerd + kubelet"
            echo -e "  • Limpiar caché de estado (${BASE_DIR}/state)"
            ;;
        WORKER)
            echo -e "  • kubeadm reset -f"
            echo -e "  • Eliminar /etc/cni, /etc/kubernetes, /var/lib/kubelet"
            echo -e "  • Eliminar /var/lib/dockershim, /var/run/kubernetes, ~/.kube/*"
            echo -e "  • Limpiar interfaces CNI, iptables (filter/nat/raw/mangle), IPVS"
            echo -e "  • Limpiar storage: /opt/local-path-provisioner"
            echo -e "  • Reiniciar servicios base: containerd + kubelet"
            echo -e "  • Limpiar caché de estado (${BASE_DIR}/state)"
            ;;
        BALANCEADOR)
            echo -e "  • Detener y deshabilitar HAProxy y Keepalived"
            echo -e "  • Revertir configuración HAProxy a backup o vaciar"
            echo -e "  • Revertir configuración Keepalived"
            echo -e "  • Eliminar VIPs de las interfaces de red"
            ;;
    esac

    echo
    if [[ "$FORCE_MODE" != "--force" ]]; then
        echo -e "${YELLOW}[ATENCIÓN]${NC} Este script realizará cambios IRREVERSIBLES en este servidor."
        echo -e "           Para confirmar y continuar escriba: ${BOLD}${RED}CONTINUAR${NC}"
        echo -n "           Respuesta: "
        read -r _confirm
        if [[ "$_confirm" != "CONTINUAR" ]]; then
            echo -e "\n${YELLOW}Operación cancelada por el usuario.${NC}"
            exit 0
        fi
    else
        log_warn "Modo --force activo: omitiendo confirmación interactiva."
    fi
    echo
}

# ---------------------------------------------------------------------------
# 5. Funciones de limpieza comunes (K8s)
# ---------------------------------------------------------------------------

# 5a. Detener kubelet de forma segura
stop_kubelet() {
    log_step "Deteniendo kubelet"
    if systemctl is-active kubelet &>/dev/null; then
        systemctl stop kubelet || true
        log_ok "kubelet detenido"
    else
        log_info "kubelet ya está inactivo"
    fi
    systemctl disable kubelet 2>/dev/null || true
}

# 5b. kubeadm reset
run_kubeadm_reset() {
    log_step "Ejecutando kubeadm reset"
    if command -v kubeadm &>/dev/null; then
        kubeadm reset -f 2>&1 || true
        log_ok "kubeadm reset completado"
    else
        log_warn "kubeadm no está instalado o no está en PATH, omitiendo."
    fi
}

# 5c. Limpiar directorios de Kubernetes
# Incluye todos los paths de la secuencia validada en 07-ops-troubleshooting.md §14
clean_k8s_dirs() {
    local is_manager="${1:-false}"
    log_step "Limpiando directorios Kubernetes"

    # Paths comunes a MANAGER y WORKER
    local dirs=(
        "/etc/cni"                  # CNI completo (no solo net.d)
        "/etc/kubernetes"           # Configuración del control plane
        "/var/lib/cni"              # Estado runtime CNI
        "/var/lib/dockershim"       # Residuo de Docker shim (si existió)
        "/var/lib/kubelet"          # Estado del agente kubelet
        "/var/run/kubernetes"       # Sockets/PIDs runtime de K8s
    )

    # Solo en MANAGER: eliminar datos de etcd
    [[ "$is_manager" == true ]] && dirs+=("/var/lib/etcd")

    for d in "${dirs[@]}"; do
        if [[ -d "$d" || -f "$d" ]]; then
            rm -rf "$d"
            log_ok "Eliminado: $d"
        else
            log_info "Ya limpio: $d"
        fi
    done

    # Limpiar contenido de ~/.kube preservando el directorio padre
    if [[ -d "${HOME}/.kube" ]]; then
        rm -rf "${HOME}/.kube/"*
        log_ok "Limpiado: ${HOME}/.kube/*"
    else
        log_info "Ya limpio: ${HOME}/.kube"
    fi
}

# 5d. Limpiar interfaces CNI residuales
clean_cni_interfaces() {
    log_step "Limpiando interfaces CNI residuales"
    local cni_ifaces=("cni0" "flannel.1" "calico_si" "tunl0" "vxlan.calico" "vxlan-v6.calico" "wireguard.cali")
    for iface in "${cni_ifaces[@]}"; do
        if ip link show "$iface" &>/dev/null; then
            ip link set "$iface" down 2>/dev/null || true
            ip link delete "$iface" 2>/dev/null || true
            log_ok "Interfaz eliminada: $iface"
        fi
    done
    # También limpiar interfaces veth huérfanas
    for veth in $(ip link show | grep -oP 'veth[a-z0-9]+' | sort -u 2>/dev/null || true); do
        ip link delete "$veth" 2>/dev/null || true
        log_info "Interfaz veth eliminada: $veth"
    done
}

# 5e. Limpiar reglas iptables relacionadas a Kubernetes
# Tablas: filter (default), nat, raw, mangle — alineado con §14 de 07-ops-troubleshooting.md
clean_iptables() {
    log_step "Limpiando reglas iptables de Kubernetes"
    if ! command -v iptables &>/dev/null; then
        log_warn "iptables no disponible, omitiendo"
        return
    fi

    # --- iptables ---
    # filter (tabla default): flush todas las cadenas + eliminar cadenas de usuario
    iptables -F 2>/dev/null || true
    iptables -X 2>/dev/null || true
    # nat: reglas DNAT/SNAT de kube-proxy
    iptables -t nat -F 2>/dev/null || true
    iptables -t nat -X 2>/dev/null || true
    # raw: reglas de conntrack de Kubernetes
    iptables -t raw -F 2>/dev/null || true
    iptables -t raw -X 2>/dev/null || true
    # mangle: marcas de paquetes de Kubernetes
    iptables -t mangle -F 2>/dev/null || true
    iptables -t mangle -X 2>/dev/null || true
    # Restablecer políticas por defecto a ACCEPT
    iptables -P INPUT   ACCEPT 2>/dev/null || true
    iptables -P FORWARD ACCEPT 2>/dev/null || true
    iptables -P OUTPUT  ACCEPT 2>/dev/null || true
    log_ok "iptables limpiadas (filter/nat/raw/mangle)"

    # --- ip6tables (mismas tablas para IPv6) ---
    if command -v ip6tables &>/dev/null; then
        ip6tables -F 2>/dev/null || true
        ip6tables -X 2>/dev/null || true
        ip6tables -t nat    -F 2>/dev/null || true
        ip6tables -t nat    -X 2>/dev/null || true
        ip6tables -t raw    -F 2>/dev/null || true
        ip6tables -t raw    -X 2>/dev/null || true
        ip6tables -t mangle -F 2>/dev/null || true
        ip6tables -t mangle -X 2>/dev/null || true
        ip6tables -P INPUT   ACCEPT 2>/dev/null || true
        ip6tables -P FORWARD ACCEPT 2>/dev/null || true
        ip6tables -P OUTPUT  ACCEPT 2>/dev/null || true
        log_ok "ip6tables limpiadas (filter/nat/raw/mangle)"
    else
        log_info "ip6tables no disponible, omitiendo"
    fi
}

# 5f. Limpiar IPVS si existe
clean_ipvs() {
    log_step "Limpiando reglas IPVS"
    if command -v ipvsadm &>/dev/null; then
        ipvsadm --clear 2>/dev/null || true
        log_ok "Tabla IPVS limpiada"
    else
        log_info "ipvsadm no instalado, omitiendo"
    fi
}

# 5g. Limpiar estado de containerd (sockets/estado runtime, SIN imágenes)
clean_containerd_state() {
    log_step "Limpiando estado residual de containerd (sin imágenes)"

    # Detener containerd
    if systemctl is-active containerd &>/dev/null; then
        systemctl stop containerd || true
        log_ok "containerd detenido"
    fi

    # Eliminar sockets y estado runtime (no el store de imágenes)
    local state_dirs=(
        "/run/containerd"
        "/var/run/containerd"
        "/var/lib/containerd/io.containerd.runtime.v1.linux"
        "/var/lib/containerd/io.containerd.runtime.v2.task"
        "/var/lib/containerd/tmpmounts"
    )
    for d in "${state_dirs[@]}"; do
        if [[ -d "$d" ]]; then
            rm -rf "$d"
            log_ok "Eliminado estado runtime: $d"
        fi
    done

    # Limpiar sockets huérfanos de kubelet (solo si el directorio aún existe)
    # BUG CORREGIDO: en el WORKER, /var/lib/kubelet ya fue borrado en clean_k8s_dirs
    # antes de llamar a clean_containerd_state — el find fallaba silenciosamente
    if [[ -d "/var/lib/kubelet/pods" ]]; then
        find /var/lib/kubelet/pods -type s -delete 2>/dev/null || true
    fi

    # Reiniciar containerd para aplicar estado limpio
    systemctl start containerd 2>/dev/null || true
    log_ok "containerd reiniciado con estado limpio"
}

# 5h. Reiniciar servicios base post-reset
# Equivalente al bloque final de §14 en 07-ops-troubleshooting.md:
#   systemctl daemon-reload && systemctl restart containerd && systemctl restart kubelet
restart_base_services() {
    log_step "Reiniciando servicios base (daemon-reload → containerd → kubelet)"

    # Recargar unidades systemd para que desaparezcan referencias a sockets eliminados
    systemctl daemon-reload 2>/dev/null || true
    log_ok "systemctl daemon-reload ejecutado"

    # BUG CORREGIDO: systemctl list-unit-files siempre retorna 0 aunque la unidad no exista
    # Usar 'systemctl cat' que sí falla si la unidad no existe
    # Reiniciar containerd (ya limpio de estado residual)
    if systemctl cat containerd.service &>/dev/null; then
        systemctl restart containerd 2>/dev/null || true
        log_ok "containerd reiniciado"
    else
        log_warn "containerd.service no encontrado, omitiendo restart"
    fi

    # Reiniciar kubelet para que arranque desde cero al próximo join/init
    if systemctl cat kubelet.service &>/dev/null; then
        systemctl restart kubelet 2>/dev/null || true
        log_ok "kubelet reiniciado (esperará nuevo kubeadm init/join)"
    else
        log_warn "kubelet.service no encontrado, omitiendo restart"
    fi
}

# 5i. Limpiar caché de estado del script
clean_script_state() {
    log_step "Limpiando caché de estado del script"
    # Tomar la variable K8S_CACHE_DIR desde el entorno (o valor por defecto)
    local env_file="${K8S_VARIABLES:-${BASE_DIR}/cluster.env}"
    local cache_dir="${BASE_DIR}/state"
    if [[ -f "$env_file" ]]; then
        local env_cache
        env_cache=$(grep -oP '^K8S_CACHE_DIR=\K[^\s"]+' "$env_file" 2>/dev/null || true)
        [[ -n "$env_cache" ]] && cache_dir="$env_cache"
    fi

    if [[ -d "$cache_dir" ]]; then
        rm -rf "${cache_dir:?}" 2>/dev/null || true
        log_ok "Directorio de caché eliminado por completo: $cache_dir"
    else
        log_info "No existe directorio de caché: $cache_dir"
    fi
}

# 5j. Limpiar cluster.env conservando SOLO las variables válidas entre migraciones,
#     y vaciar inventory.csv para forzar re-entrada de IPs/hostnames en la nueva red.
#
# ESTRATEGIA: Lista blanca (allowlist) — más segura que lista negra:
#   Se conservan únicamente las variables que tienen sentido en cualquier ambiente.
#   Cualquier variable fuera de esta lista (IP_*, HOSTNAME_*, VIRTUAL_IP_*,
#   o cualquier variable nueva desconocida) se elimina automáticamente.
#
# VARIABLES PRESERVADAS:
#   Rutas base    : K8S_BASE_DIR, K8S_VARIABLES, K8S_INVENTORY,
#                   K8S_CACHE_DIR, YAML_BASE_PATH
#   Plataforma K8s: KUBERNETES_VERSION, NGX_SVC_HTTP_NODEPORT, NGX_SVC_HTTPS_NODEPORT
clean_network_config() {
    log_step "Limpiando configuración de red (cluster.env e inventory.csv)"
    local env_file="${K8S_VARIABLES:-${BASE_DIR}/cluster.env}"
    local inv_file="${K8S_INVENTORY:-${BASE_DIR}/inventory.csv}"

    # --- cluster.env: preservar SOLO la lista blanca de variables ---
    if [[ -f "$env_file" ]]; then
        local total_before removed_count

        total_before=$(grep -c '.' "$env_file" 2>/dev/null || true)

        # Lista blanca: patrón grep que captura cada variable permitida
        # con o sin prefijo 'export '
        local allowlist_pattern
        allowlist_pattern='^(export )?('
        allowlist_pattern+='K8S_BASE_DIR'
        allowlist_pattern+='|K8S_VARIABLES'
        allowlist_pattern+='|K8S_INVENTORY'
        allowlist_pattern+='|K8S_CACHE_DIR'
        allowlist_pattern+='|YAML_BASE_PATH'
        allowlist_pattern+='|KUBERNETES_VERSION'
        allowlist_pattern+='|NGX_SVC_HTTP_NODEPORT'
        allowlist_pattern+='|NGX_SVC_HTTPS_NODEPORT'
        allowlist_pattern+=')='

        # Reescribir el archivo conservando solo las líneas de la lista blanca
        local tmp_env
        tmp_env=$(mktemp)
        grep -E "$allowlist_pattern" "$env_file" 2>/dev/null > "$tmp_env" || true
        mv -f "$tmp_env" "$env_file"

        local total_after
        total_after=$(grep -c '.' "$env_file" 2>/dev/null || true)
        removed_count=$(( total_before - total_after ))

        if [[ $removed_count -gt 0 ]]; then
            log_ok "cluster.env: $removed_count líneas eliminadas — conservadas $total_after variables de la lista permitida"
        else
            log_info "cluster.env: no había variables fuera de la lista permitida"
        fi

        # Si tras filtrar el archivo quedó vacío, eliminarlo directamente
        if [[ ! -s "$env_file" ]]; then
            rm -f "$env_file"
            log_ok "cluster.env eliminado (no quedaron variables de la lista permitida)"
        fi
    else
        log_info "cluster.env no existe, nada que limpiar"
    fi

    # --- inventory.csv: vaciar completamente ---
    # IPs y hostnames son siempre específicos de la red; el script 03 los regenera
    if [[ -f "$inv_file" ]]; then
        > "$inv_file"
        log_ok "inventory.csv vaciado — debe ser completado con las nuevas IPs antes de ejecutar 03-setup-prod-ha.sh"
    else
        log_info "inventory.csv no existe, nada que vaciar"
    fi
}

# ---------------------------------------------------------------------------
# 6. Acciones específicas por ROL
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 6a. Helpers de espera para eliminación de recursos K8s
# ---------------------------------------------------------------------------

# wait_deleted RESOURCE NAMESPACE
# Espera hasta que no queden recursos del tipo dado (timeout 3 min, polling 5s)
# BUG CORREGIDO: PVs y StorageClasses son cluster-scoped → no usan -n ni --all-namespaces
# Uso:   wait_deleted "pods" "ingress-nginx"   # recursos namespaced
#        wait_deleted "pv"   ""           # recursos cluster-scoped (ns vacío)
wait_deleted() {
    local resource="$1"
    local ns="${2:-}"
    local timeout=180   # 3 minutos máximo
    local interval=5
    local elapsed=0

    # Recursos cluster-scoped (sin namespace): pv, storageclass, namespace, clusterrole*
    local cluster_scoped_pattern="^(pv|persistentvolume|storageclass|namespace|clusterrole|clusterrolebinding|node)s?$"
    local ns_flag
    if [[ -n "$ns" ]]; then
        ns_flag="-n $ns"
    elif [[ "$resource" =~ $cluster_scoped_pattern ]]; then
        ns_flag=""          # cluster-scoped: sin flag de namespace
    else
        ns_flag="--all-namespaces"
    fi

    while true; do
        local count
        # BUG CORREGIDO: || echo 0 dentro de $() no funciona con set -u
        # Se captura la salida y se hace el default fuera del subshell
        count=$(kubectl $ns_flag get "$resource" --no-headers 2>/dev/null | wc -l) || count=0
        count=$(( count + 0 ))  # forzar a número

        if [[ "$count" -eq 0 ]]; then
            log_ok "Confirmado: 0 ${resource} restantes${ns:+ en ns=$ns}"
            return 0
        fi

        if [[ "$elapsed" -ge "$timeout" ]]; then
            log_warn "Timeout (${timeout}s) esperando ${resource}${ns:+/$ns} — continúa de todas formas"
            return 0
        fi

        echo -ne "  ${YELLOW}[ESPERA]${NC} ${resource}${ns:+/$ns}: ${count} restantes... (${elapsed}s/${timeout}s)\r"
        sleep "$interval"
        elapsed=$(( elapsed + interval ))
    done
}

# k8s_clean_namespace NS
# Elimina en orden todos los recursos dentro de un namespace dado, con esperas.
k8s_clean_namespace() {
    local ns="$1"

    if ! kubectl get namespace "$ns" &>/dev/null; then
        log_info "Namespace no existe: $ns (ya limpio)"
        return 0
    fi

    log_info "→ Limpiando namespace: ${MAGENTA}${ns}${NC}"

    # 1. Workloads (en orden: pods de mayor a menor nivel de abstracción)
    #    StatefulSets primero porque controlan PVCs
    for kind in statefulsets deployments daemonsets replicasets jobs cronjobs pods; do
        local cnt
        cnt=$(kubectl -n "$ns" get "$kind" --no-headers 2>/dev/null | wc -l || echo 0)
        if [[ "$cnt" -gt 0 ]]; then
            log_info "  Eliminando $cnt ${kind} en $ns"
            kubectl -n "$ns" delete "$kind" --all --grace-period=10 2>/dev/null || true
            wait_deleted "$kind" "$ns"
        fi
    done

    # 2. Ingresses y Services (liberar endpoints antes de eliminar PVCs)
    for kind in ingresses services; do
        local cnt
        cnt=$(kubectl -n "$ns" get "$kind" --no-headers 2>/dev/null | \
              grep -v '^kubernetes ' | wc -l || echo 0)
        if [[ "$cnt" -gt 0 ]]; then
            log_info "  Eliminando $cnt ${kind} en $ns"
            kubectl -n "$ns" delete "$kind" --all 2>/dev/null || true
            wait_deleted "$kind" "$ns"
        fi
    done

    # 3. PVCs — el paso más lento: dispara reclaim del PV en los workers
    local pvc_cnt
    pvc_cnt=$(kubectl -n "$ns" get pvc --no-headers 2>/dev/null | wc -l || echo 0)
    if [[ "$pvc_cnt" -gt 0 ]]; then
        log_info "  Eliminando $pvc_cnt PVC(s) en $ns (puede tardar — espera hasta 3 min)"
        kubectl -n "$ns" delete pvc --all --grace-period=10 2>/dev/null || true
        wait_deleted "pvc" "$ns"
    fi

    # 4. ConfigMaps y Secrets
    for kind in configmaps secrets; do
        local cnt
        cnt=$(kubectl -n "$ns" get "$kind" --no-headers 2>/dev/null | wc -l || echo 0)
        if [[ "$cnt" -gt 0 ]]; then
            log_info "  Eliminando $cnt ${kind} en $ns"
            kubectl -n "$ns" delete "$kind" --all 2>/dev/null || true
        fi
    done

    # 5. RBAC del namespace
    for kind in rolebindings roles serviceaccounts; do
        local cnt
        cnt=$(kubectl -n "$ns" get "$kind" --no-headers 2>/dev/null | wc -l || echo 0)
        if [[ "$cnt" -gt 0 ]]; then
            log_info "  Eliminando $cnt ${kind} en $ns"
            kubectl -n "$ns" delete "$kind" --all 2>/dev/null || true
        fi
    done

    log_ok "Namespace ${ns} vaciado"
}

# ------ MANAGER ------
teardown_manager() {
    log_step "INICIO TEARDOWN — ROL: MANAGER"

    # -------------------------------------------------------------------
    # 6a. Limpieza de recursos Kubernetes (solo si el API server responde)
    # -------------------------------------------------------------------
    log_step "Limpiando recursos Kubernetes vía API server"

    if ! command -v kubectl &>/dev/null; then
        log_warn "kubectl no instalado — se omite limpieza de recursos K8s"
    elif ! kubectl get nodes &>/dev/null 2>&1; then
        log_warn "API Server no alcanzable — se omite limpieza de recursos K8s"
    else
        log_info "API Server alcanzable — iniciando limpieza ordenada"

        # ── PASO 1: Desinstalar Helm releases (elimina pods/RS antes de PVCs) ──
        log_step "PASO 1/8 — Desinstalando Helm releases"
        if command -v helm &>/dev/null; then
            if helm status ingress-nginx -n ingress-nginx &>/dev/null; then
                log_info "  helm uninstall ingress-nginx (ns=ingress-nginx)"
                helm uninstall ingress-nginx -n ingress-nginx --wait --timeout 120s 2>/dev/null || true
                log_ok "  Helm release eliminado: ingress-nginx"
            else
                log_info "  Helm release no encontrado: ingress-nginx"
            fi
            if helm status local-path-storage -n local-path-storage &>/dev/null; then
                log_info "  helm uninstall local-path-storage (ns=local-path-storage)"
                helm uninstall local-path-storage -n local-path-storage \
                    --wait --timeout 60s 2>/dev/null || true
                log_ok "  Helm release eliminado: local-path-storage"
            fi
        else
            log_info "  helm no instalado — se omite desinstalación de releases"
        fi

        # ── PASO 2: Limpiar workloads y red de cada namespace en orden ──
        log_step "PASO 2/8 — Limpiando workloads, Ingresses y Services por namespace"
        local managed_namespaces=("ingress-nginx" "local-path-storage")
        for ns in "${managed_namespaces[@]}"; do
            k8s_clean_namespace "$ns"
        done

        # ── PASO 3: Esperar que los PVs queden Released o sean eliminados ──
        log_step "PASO 3/8 — Esperando liberación de PersistentVolumes"
        local pv_cnt
        pv_cnt=$(kubectl get pv --no-headers 2>/dev/null | \
                 grep -vE '^$' | wc -l || echo 0)
        if [[ "$pv_cnt" -gt 0 ]]; then
            log_info "  Detectados $pv_cnt PV(s) — esperando que queden Released/Deleted"
            wait_deleted "pv" ""
            # Si quedaron PVs en estado Released/Failed, forzar eliminación
            local orphan_pvs
            orphan_pvs=$(kubectl get pv --no-headers 2>/dev/null | \
                         awk '$5 ~ /Released|Failed|Available/ {print $1}' || true)
            if [[ -n "$orphan_pvs" ]]; then
                log_info "  Eliminando PVs huérfanos (Released/Failed):"
                while IFS= read -r pv_name; do
                    [[ -z "$pv_name" ]] && continue
                    log_info "    kubectl delete pv $pv_name"
                    kubectl delete pv "$pv_name" --grace-period=5 2>/dev/null || true
                done <<< "$orphan_pvs"
                wait_deleted "pv" ""
            fi
        else
            log_ok "  No hay PVs pendientes"
        fi

        # ── PASO 4: Eliminar StorageClasses ──
        log_step "PASO 4/8 — Eliminando StorageClasses"
        local sc_list
        sc_list=$(kubectl get storageclass --no-headers 2>/dev/null | \
                  awk '{print $1}' || true)
        if [[ -n "$sc_list" ]]; then
            while IFS= read -r sc; do
                [[ -z "$sc" ]] && continue
                log_info "  Eliminando StorageClass: $sc"
                kubectl delete storageclass "$sc" 2>/dev/null || true
            done <<< "$sc_list"
            log_ok "  StorageClasses eliminados"
        else
            log_ok "  Sin StorageClasses que eliminar"
        fi

        # ── PASO 5: RBAC global (ClusterRoles / ClusterRoleBindings de Ingress / local-path) ──
        log_step "PASO 5/8 — Limpiando RBAC global (ClusterRoles / ClusterRoleBindings)"
        local k8s_pattern="ingress-nginx\|local-path"
        for kind in clusterrolebindings clusterroles; do
            local items
            items=$(kubectl get "$kind" --no-headers 2>/dev/null | \
                    grep -E "$k8s_pattern" | awk '{print $1}' || true)
            if [[ -n "$items" ]]; then
                while IFS= read -r item; do
                    [[ -z "$item" ]] && continue
                    log_info "  Eliminando $kind/$item"
                    kubectl delete "$kind" "$item" 2>/dev/null || true
                done <<< "$items"
                log_ok "  $kind relacionados eliminados"
            else
                log_ok "  Sin $kind relacionados"
            fi
        done

        # ── PASO 6: Eliminar namespaces y esperar terminación ──
        log_step "PASO 6/8 — Eliminando namespaces y esperando terminación"
        for ns in "${managed_namespaces[@]}"; do
            if kubectl get namespace "$ns" &>/dev/null; then
                log_info "  kubectl delete namespace $ns"
                kubectl delete namespace "$ns" --grace-period=10 2>/dev/null || true
            fi
        done
        # Esperar que cada namespace desaparezca (máx 3 min por namespace)
        for ns in "${managed_namespaces[@]}"; do
            local elapsed=0
            local interval=5
            local timeout=180
            while kubectl get namespace "$ns" &>/dev/null; do
                if [[ "$elapsed" -ge "$timeout" ]]; then
                    log_warn "  Timeout esperando terminación de namespace $ns — continuando"
                    break
                fi
                echo -ne "  ${YELLOW}[ESPERA]${NC} namespace/$ns terminando... (${elapsed}s/${timeout}s)\r"
                sleep "$interval"
                elapsed=$(( elapsed + interval ))
            done
            kubectl get namespace "$ns" &>/dev/null || log_ok "  Namespace eliminado: $ns"
        done

        # ── PASO 7: PVs residuales finales (fuerza bruta si quedan) ──
        log_step "PASO 7/8 — Verificación final de PVs residuales"
        local final_pvs
        final_pvs=$(kubectl get pv --no-headers 2>/dev/null | \
                    awk '{print $1}' || true)
        if [[ -n "$final_pvs" ]]; then
            log_warn "  Aún quedan PVs — aplicando force delete:"
            while IFS= read -r pv_name; do
                [[ -z "$pv_name" ]] && continue
                log_info "    Eliminando PV: $pv_name"
                # Quitar finalizers si el PV está atascado en Terminating
                kubectl patch pv "$pv_name" \
                    -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
                kubectl delete pv "$pv_name" --grace-period=0 --force 2>/dev/null || true
            done <<< "$final_pvs"
        else
            log_ok "  Sin PVs residuales — clúster limpio de almacenamiento"
        fi

        log_ok "Limpieza de recursos K8s completada"
    fi

    # ── Limpiar archivos generados (SIEMPRE) ──
    log_step "Limpiando manifiestos generados"

    # -------------------------------------------------------------------
    # 6b. Reset del nodo (kubeadm + sistema)
    # -------------------------------------------------------------------
    stop_kubelet
    run_kubeadm_reset
    clean_cni_interfaces
    clean_iptables
    clean_ipvs
    clean_k8s_dirs true   # true = también /var/lib/etcd
    clean_containerd_state
    clean_script_state
    clean_network_config
    restart_base_services

    log_ok "TEARDOWN MANAGER completado"
}

# ------ WORKER ------
teardown_worker() {
    log_step "INICIO TEARDOWN — ROL: WORKER"

    # -----------------------------------------------------------------------
    # ORDEN DE DESINSTALACIÓN — Por qué importa:
    #
    # 1. stop_kubelet          → Para que no re-monte nada mientras limpiamos
    # 2. Desmontar PV mounts   → Los dirs de /opt/local-path-provisioner
    #                            están bind-montados por kubelet; hay que
    #                            liberarlos ANTES del rm -rf
    # 3. Desmontar bind mounts → /var/lib/kubelet/pods/* también tiene mounts
    #                            activos en el kernel; liberar ANTES de rm -rf
    # 4. kubeadm reset -f      → Limpieza oficial de estado del nodo
    # 5. CNI / iptables / IPVS → Red virtualizada residual
    # 6. clean_k8s_dirs        → rm -rf seguro (mounts ya liberados en pasos 2-3)
    # 7. Storage /opt/local-path-provisioner → rm -rf seguro (desmontado en paso 2)
    # 8. containerd state      → Sockets y estado runtime
    # 9. restart_base_services → daemon-reload → containerd → kubelet
    # -----------------------------------------------------------------------

    # PASO 1: Detener kubelet para que no re-monte volúmenes
    stop_kubelet

    # PASO 2: Desmontar PV mounts de /opt/local-path-provisioner
    # kubelet crea bind mounts desde /opt/local-path-provisioner/<pv>
    # hacia /var/lib/kubelet/pods/<uid>/volumes/... → hay que liberarlos primero
    log_step "Desmontando PV mounts activos (local-path-provisioner)"
    local lpp_root="/opt/local-path-provisioner"
    local pv_mounts
    pv_mounts=$(mount | awk -v base="$lpp_root" '$3 ~ base {print $3}' | sort -r 2>/dev/null || true)
    if [[ -n "$pv_mounts" ]]; then
        while IFS= read -r mp; do
            umount -f "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
            log_info "Desmontado PV: $mp"
        done <<< "$pv_mounts"
        log_ok "PV mounts liberados"
    else
        log_info "Sin PV mounts activos en $lpp_root"
    fi

    # PASO 3: Desmontar bind mounts residuales de kubelet pods
    # Kubernetes crea bind mounts para volúmenes en /var/lib/kubelet/pods/
    # Deben liberarse antes del rm -rf o quedan colgados en el kernel
    log_step "Desmontando bind mounts de kubelet (pods)"
    local kubelet_mounts
    kubelet_mounts=$(mount | awk '$3 ~ /\/var\/lib\/kubelet/ {print $3}' | sort -r 2>/dev/null || true)
    if [[ -n "$kubelet_mounts" ]]; then
        while IFS= read -r mp; do
            umount -f "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
            log_info "Desmontado: $mp"
        done <<< "$kubelet_mounts"
        log_ok "Bind mounts de kubelet liberados"
    else
        log_info "Sin bind mounts de kubelet activos"
    fi

    # PASO 4: kubeadm reset (limpieza oficial del nodo)
    run_kubeadm_reset

    # PASO 5: Red virtualizada residual
    clean_cni_interfaces
    clean_iptables
    clean_ipvs

    # PASO 6: Directorios K8s (ahora seguro, mounts ya liberados)
    clean_k8s_dirs false  # false = NO /var/lib/etcd en workers

    # PASO 7: Eliminar storage de PVs (directorio completo)
    # Los mounts ya fueron liberados en el PASO 2
    log_step "Eliminando storage local-path-provisioner"
    if [[ -d "$lpp_root" ]]; then
        rm -rf "${lpp_root:?}"
        log_ok "Storage eliminado: $lpp_root"
    else
        log_info "No existe: $lpp_root (ya limpio)"
    fi

    # PASO 8: Estado residual de containerd (sin borrar imágenes)
    clean_containerd_state

    # PASO 9: Caché del script + reinicio de servicios base
    clean_script_state
    clean_network_config
    restart_base_services

    log_ok "TEARDOWN WORKER completado"
}

# ------ BALANCEADOR ------
teardown_balanceador() {
    log_step "INICIO TEARDOWN — ROL: BALANCEADOR"

    # 6c. Detener Keepalived
    log_step "Deteniendo Keepalived"
    if systemctl is-active keepalived &>/dev/null; then
        systemctl stop keepalived 2>/dev/null || true
        log_ok "keepalived detenido"
    else
        log_info "keepalived ya está inactivo"
    fi
    systemctl disable keepalived 2>/dev/null || true

    # Eliminar VIPs de las interfaces (Keepalived los habría asignado)
    # Detectamos IPs VIP desde cluster.env si existe
    local env_file="${K8S_VARIABLES:-${BASE_DIR}/cluster.env}"
    if [[ -f "$env_file" ]]; then
        local vip_k8s vip_ingress
        vip_k8s=$(grep -oP 'VIRTUAL_IP_K8S=\K[^\s"]+' "$env_file" 2>/dev/null || true)
        vip_ingress=$(grep -oP 'VIRTUAL_IP_INGRESS=\K[^\s"]+' "$env_file" 2>/dev/null || true)

        for vip in "$vip_k8s" "$vip_ingress"; do
            [[ -z "$vip" ]] && continue
            local iface
            # BUG CORREGIDO: /32 hardcodeado es incorrecto para IPs en subredes /24, /16, etc.
            # Se extrae el prefijo real desde 'ip addr show' (ej: 192.168.18.200/24)
            local addr_with_prefix
            addr_with_prefix=$(ip -o addr show | awk -v ip="$vip" '$4 ~ ip"/" {print $4; exit}' 2>/dev/null || true)
            iface=$(ip -o addr show | awk -v ip="$vip" '$4 ~ ip"/" {print $2; exit}' 2>/dev/null || true)
            if [[ -n "$iface" && -n "$addr_with_prefix" ]]; then
                ip addr del "$addr_with_prefix" dev "$iface" 2>/dev/null || true
                log_ok "VIP eliminada: $addr_with_prefix (interfaz: $iface)"
            else
                log_info "VIP no activa en este nodo: $vip"
            fi
        done
    fi

    # 6d. Revertir configuración Keepalived
    log_step "Revirtiendo configuración Keepalived"
    local kd_conf="/etc/keepalived/keepalived.conf"
    if [[ -f "${kd_conf}.bkp" ]]; then
        cp "${kd_conf}.bkp" "$kd_conf"
        log_ok "keepalived.conf restaurado desde backup"
    elif [[ -f "$kd_conf" ]]; then
        # No hay backup: vaciar con configuración mínima inofensiva
        cat > "$kd_conf" << 'EOF'
# keepalived.conf - resetted by 08-teardown-servers.sh
# Reconfigure before next cluster deployment
global_defs {
   router_id RESET
}
EOF
        log_ok "keepalived.conf vaciado (sin backup previo)"
    else
        log_info "keepalived.conf no existe"
    fi

    # 6e. Detener HAProxy
    log_step "Deteniendo HAProxy"
    if systemctl is-active haproxy &>/dev/null; then
        systemctl stop haproxy 2>/dev/null || true
        log_ok "haproxy detenido"
    else
        log_info "haproxy ya está inactivo"
    fi
    systemctl disable haproxy 2>/dev/null || true

    # 6f. Revertir configuración HAProxy
    log_step "Revirtiendo configuración HAProxy"
    local hp_conf="/etc/haproxy/haproxy.cfg"
    if [[ -f "${hp_conf}.bkp" ]]; then
        cp "${hp_conf}.bkp" "$hp_conf"
        log_ok "haproxy.cfg restaurado desde backup"
    elif [[ -f "$hp_conf" ]]; then
        # Escribir configuración mínima válida por defecto
        cat > "$hp_conf" << 'EOF'
# haproxy.cfg - resetted by 08-teardown-servers.sh
# Reconfigure before next cluster deployment
global
    log /dev/log local0
    log /dev/log local1 notice
    maxconn 2000
    daemon

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    timeout connect 5s
    timeout client  50s
    timeout server  50s

# Evita que 'haproxy -c' falle con exit code 2 (no listener) durante validaciones de 03-setup
listen dummy-listener
    bind 127.0.0.1:9999
    mode tcp
EOF
        log_ok "haproxy.cfg vaciado con configuración mínima (sin backup previo)"
    else
        log_info "haproxy.cfg no existe"
    fi

    # 6g. Eliminar archivos temporales generados por la instalación
    log_step "Eliminando configuraciones temporales generadas"
    local tmp_confs=(
        "/etc/haproxy/haproxy.cfg.k8s-installer"
        "/etc/keepalived/keepalived.conf.k8s-installer"
        "/tmp/haproxy-k8s.cfg"
        "/tmp/keepalived-k8s.conf"
    )
    for f in "${tmp_confs[@]}"; do
        [[ -f "$f" ]] && rm -f "$f" && log_ok "Eliminado: $f"
    done

    clean_script_state
    clean_network_config

    log_ok "TEARDOWN BALANCEADOR completado"
}

# ---------------------------------------------------------------------------
# 7. Resumen final
# ---------------------------------------------------------------------------
show_summary() {
    local SEP="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "\n${GREEN}${SEP}${NC}"
    echo -e "  ${BOLD}${GREEN}✔  RESET COMPLETADO — $(hostname) [${ROLE}]${NC}"
    echo -e "${GREEN}${SEP}${NC}"
    echo -e "  Log guardado en : ${LOG_FILE}"
    echo -e "\n  ${BOLD}Próximos pasos:${NC}"
    case "$ROLE" in
        MANAGER|WORKER)
            echo -e "  1. ${YELLOW}[RED]${NC}         Aplicar los nuevos valores de IP en el sistema operativo y la infraestructura de red"
            echo -e "  2. ${YELLOW}[/etc/hosts]${NC}  Actualizar con las nuevas IPs de TODOS los nodos: ${BOLD}/etc/hosts${NC}"
            echo -e "  3. ${YELLOW}[inventory.csv]${NC} Completar con las nuevas IPs y hostnames: ${BOLD}${BASE_DIR}/inventory.csv${NC}"
            echo -e "  4. ${YELLOW}[cluster.env]${NC}  Las variables IP_*, HOSTNAME_* y VIRTUAL_IP_* ya fueron eliminadas por este script"
            echo -e "  5. Ejecutar en TODOS los nodos: ${BOLD}./01-setup-k8s-pre-reqs.sh${NC}"
            echo -e "  6. Seguir la guía para primer MANAGER: ${BOLD}02-k8s-installation-guide.md${NC}"
            ;;
        BALANCEADOR)
            echo -e "  1. ${YELLOW}[RED]${NC}         Aplicar los nuevos valores de IP en el sistema operativo y la infraestructura de red"
            echo -e "  2. ${YELLOW}[/etc/hosts]${NC}  Actualizar con las nuevas IPs de TODOS los nodos: ${BOLD}/etc/hosts${NC}"
            echo -e "  3. ${YELLOW}[inventory.csv]${NC} Completar con las nuevas IPs y hostnames: ${BOLD}${BASE_DIR}/inventory.csv${NC}"
            echo -e "  4. ${YELLOW}[cluster.env]${NC}  Las variables IP_*, HOSTNAME_* y VIRTUAL_IP_* ya fueron eliminadas por este script"
            echo -e "  5. Ejecutar en este nodo: ${BOLD}./01-setup-k8s-pre-reqs.sh${NC}"
            ;;
    esac
    echo -e "${GREEN}${SEP}${NC}\n"
}

# ---------------------------------------------------------------------------
# 8. Validaciones previas
# ---------------------------------------------------------------------------
preflight_checks() {
    log_step "Validaciones previas"

    # Requiere root
    if [[ "$EUID" -ne 0 ]]; then
        log_err "Este script debe ejecutarse como root (EUID=$EUID)"
        exit 1
    fi

    # Inventario accesible
    if [[ ! -f "$K8S_INVENTORY" ]]; then
        log_err "Archivo de inventario no encontrado: $K8S_INVENTORY"
        exit 1
    fi

    # Rol válido
    if [[ "$ROLE" != "MANAGER" && "$ROLE" != "WORKER" && "$ROLE" != "BALANCEADOR" ]]; then
        log_err "Rol desconocido detectado: '$ROLE'. Valores válidos: MANAGER, WORKER, BALANCEADOR"
        exit 1
    fi

    log_ok "Preflight OK — Rol: ${ROLE} | Host: $(hostname)"
}

# ---------------------------------------------------------------------------
# 9. Punto de entrada principal
# ---------------------------------------------------------------------------
main() {
    # BUG CORREGIDO: FORCE_MODE debe leerse de los args de main, no del entorno global
    # Si se leyera en el scope global ($1), capturaría argumentos de funciones internas
    FORCE_MODE="${1:-}"

    preflight_checks
    show_header

    case "$ROLE" in
        MANAGER)     teardown_manager ;;
        WORKER)      teardown_worker ;;
        BALANCEADOR) teardown_balanceador ;;
        *)
            log_err "Rol no soportado: $ROLE"
            exit 1
            ;;
    esac

    show_summary

    if [[ "$FORCE_MODE" != "--force" ]]; then
        echo -e "\n${YELLOW}¿Desea reiniciar el servidor ahora para aplicar todos los cambios de red limpios? (s/N): ${NC}\c"
        read -r _reboot
        if [[ "$_reboot" =~ ^[Ss]$ ]]; then
            log_warn "Reiniciando servidor en 3 segundos..."
            sleep 3
            reboot
        else
            log_info "Reinicio omitido. Recuerde reiniciar manualmente más tarde."
        fi
    fi
}

main "$@"
