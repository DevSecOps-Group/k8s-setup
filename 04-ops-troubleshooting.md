# 04 — Operación, Troubleshooting y Escenarios HA

> **Ambiente**: Pre-productivo (Recomendado para Pruebas, Staging y Pre-producción)  
> **Autor**: Ing. Jesús A. Chávez Becerra | DevSecOps, Cloud and Infrastructure Architect  
> **Compañía**: DevSecOps Group S.A.C.  
> **Proyecto**: KUBERNETES HA ON-PREMISE  
>
> Este documento es la guía operativa del clúster en ambiente pre-productivo.  
> Usar solo los bloques que apliquen al incidente (no ejecutar todo en secuencia).

---

## Índice de secciones

| # | Sección | Frecuencia de uso |
|---|---|---|
| 0 | Contexto mínimo antes de operar | Siempre |
| **1** | **Migración de Red — Teardown y re-instalación** | **Evento planeado** |
| 2 | Health check rápido del clúster | Diario / ante incidente |
| 3 | Validación de HAProxy / Keepalived | Ante incidente de red |
| 4 | Redeploy / Rollout de aplicaciones | Tras cambios de config |
| 5 | Monitoreo del clúster | Operación continua |
| 6 | K9s — Dashboard TUI | Administración visual |
| 7 | Prueba de failover HA a nivel aplicación | Validación de HA |
| 8 | Drain de nodos | Pre-mantenimiento |
| 9 | Upgrade de Kubernetes | Mantenimiento mayor |
| 10 | Reset manual del clúster | Emergencia / reinstalación |
| 11 | Gestión de Imágenes y Rate Limit Docker Hub | Configuración inicial |
| 12 | Escenarios HA — Doble VIP vs VIP única | Referencia arquitectónica |

---

## 0. Contexto mínimo antes de operar

```bash
# Cargar variables del entorno
source /root/k8s-installer/cluster.env

# En nodos MANAGER, usar kubectl del control plane
export KUBECONFIG=/etc/kubernetes/admin.conf

# Validación rápida de contexto
echo "K8S VERSION        : ${KUBERNETES_VERSION}"
echo "VIP K8S            : ${VIRTUAL_IP_K8S:-N/A}"
echo "VIP INGRESS        : ${VIRTUAL_IP_INGRESS:-N/A}"
echo "NODEPORT HTTP/HTTPS: ${NGX_SVC_HTTP_NODEPORT:-N/A}/${NGX_SVC_HTTPS_NODEPORT:-N/A}"
```

---

## 1. Migración de Red — Teardown y re-instalación

> Usar cuando los servidores deben moverse a una nueva segmentación de red (nuevas IPs, VLANs, etc.).  
> El script `03-teardown-servers.sh` automatiza el teardown completo por rol **sin desinstalar paquetes, binarios ni imágenes**.

```bash
# Dar permisos (solo la primera vez, en cada servidor)
chmod +x /root/k8s-installer/03-teardown-servers.sh

# Ejecutar en cada servidor (detecta el rol automáticamente desde inventory.csv)
./03-teardown-servers.sh

# Modo no interactivo — sin confirmación (útil para automatización)
./03-teardown-servers.sh --force
```

### 1.1 Ejecución paralela y consideraciones

El script está diseñado de forma resiliente para **ejecutarse en paralelo o en cualquier orden** en todos los servidores al mismo tiempo. 

> **¿Qué pasa si se apaga el Control Plane primero?**  
> Si el API Server de Kubernetes queda inaccesible (por ejemplo, porque apagaste los Balanceadores o los Managers en paralelo), el script detectará que no puede usar `kubectl` e inteligentemente saltará la limpieza ordenada a nivel API para hacer un "hard reset" usando `kubeadm reset -f` y limpieza directa del sistema de archivos. El resultado final sigue siendo un servidor totalmente saneado.

### 1.2 Qué hace el script por rol

| Rol | Limpieza K8s (vía API) | Limpieza del sistema | Storage |
|---|---|---|---|
| **MANAGER** | Helm releases (Ingress/Storage) → PVC → PV → SC → NS → ClusterRBAC | `kubeadm reset`, CNI, iptables/raw/mangle, etcd | — |
| **WORKER** | Desmonta PV mounts y kubelet bind mounts (antes de rm) | `kubeadm reset`, CNI, iptables | Elimina `/opt/local-path-provisioner` completo |
| **BALANCEADOR** | — | Detiene HAProxy + Keepalived, elimina VIPs de interfaz | — |

### 1.3 Post-migración — re-instalación

```bash
# 1. Actualizar IPs en los archivos de configuración
vim /root/k8s-installer/cluster.env       # nuevas IPs, VIPs, hostnames
vim /root/k8s-installer/inventory.csv     # nuevas IPs por nodo y rol

# 2. Re-instalar el clúster usando la herramienta compliance
./01-setup-k8s-pre-reqs.sh                # en TODOS los nodos (cada uno según su rol)

# 3. Seguir la guía interactiva para el inicializador de K8s y componentes
# Ver detalles en 02-k8s-installation-guide.md
```

---

## 2. Health check rápido del clúster

```bash
# Nodos y estado general
kubectl get nodes -o wide
kubectl get pods -A -o wide

# API Server por VIP
curl -k https://${VIRTUAL_IP_K8S}:6443/readyz
curl -k https://${VIRTUAL_IP_K8S}:6443/livez

# Ingress por VIP
curl -k https://${VIRTUAL_IP_INGRESS}
```

---

## 3. Validación de HAProxy / Keepalived

> Ejecutar en balanceadores.

```bash
# Sintaxis de HAProxy
haproxy -c -f /etc/haproxy/haproxy.cfg

# Estado del servicio
systemctl status haproxy --no-pager -l

# Ver puertos de escucha
ss -nltp | egrep ':6443|:80|:443'

# (Opcional) Estadísticas por socket (si está configurado)
echo "show stat" | socat - UNIX-CONNECT:/var/run/haproxy.sock
```

```bash
# Estado de Keepalived
systemctl status keepalived --no-pager -l

# Ver VIPs activas en la interfaz
ip -4 addr show | egrep "${VIRTUAL_IP_K8S}|${VIRTUAL_IP_INGRESS}"
```

---

## 4. Redeploy / Rollout de aplicaciones

> Usar cuando se cambian valores YAML, se actualizan Charts o tras `helm upgrade`.

```bash
# Reinicio masivo de pods de Ingress (todo el namespace)
kubectl -n ingress-nginx rollout restart deployment
kubectl -n ingress-nginx rollout status deployment

# Reinicio de controlador de almacenamiento local-path-storage
kubectl -n local-path-storage rollout restart deployment local-path-provisioner
kubectl -n local-path-storage rollout status deployment local-path-provisioner
```

---

## 5. Monitoreo del clúster

```bash
cat <<'EOF' > k8s-watch.sh
#!/usr/bin/env bash
clear

echo "==================== NODES ===================="
kubectl get nodes -o wide

echo
echo "==================== INGRESS NGINX ================="
kubectl -n ingress-nginx get pods -o wide --no-headers 2>/dev/null || echo "Ingress Nginx no instalado o sin pods"

echo
echo "==================== STORAGE ===================="
kubectl -n local-path-storage get pods -o wide --no-headers 2>/dev/null || echo "Local Path Storage no instalado o sin pods"
EOF

chmod +x k8s-watch.sh
watch -n 1 -t ./k8s-watch.sh
```

---

## 6. K9s — Dashboard TUI de Kubernetes

> Ejecutar en el nodo Control Plane (MANAGER).

```bash
curl -LO https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_amd64.tar.gz
tar -xzf k9s_Linux_amd64.tar.gz && rm -rf LICENSE README.md
chmod +x k9s && mv k9s /usr/local/bin/
export KUBECONFIG=/etc/kubernetes/admin.conf
k9s
```

---

## 7. Prueba de failover HA a nivel aplicación

> Ejecutar en el primer nodo MANAGER. Despliega un pod de prueba distribuido para validar la alta disponibilidad y tolerancia a fallos.

```bash
kubectl get ns kubernetes-ha-demo 2>/dev/null || kubectl create ns kubernetes-ha-demo

cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: k8s-ha-demo
  namespace: kubernetes-ha-demo
spec:
  replicas: 3
  selector:
    matchLabels:
      app: k8s-ha-demo
  template:
    metadata:
      labels:
        app: k8s-ha-demo
    spec:
      terminationGracePeriodSeconds: 5
      containers:
      - name: web
        image: busybox:1.36
        env:
        - name: POD_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        command:
        - /bin/sh
        - -c
        - |
          mkdir -p /www
          while true; do
            echo "<html><body style='background:#0b132b;color:#e0fbfc;font-family:Arial;text-align:center;margin-top:40px'>" > /www/index.html
            echo "<h1>KUBERNETES HA FAILOVER DEMO</h1>" >> /www/index.html
            echo "<h2>Ing. Jesús A. Chávez Becerra | DevSecOps Group S.A.C.</h2>" >> /www/index.html
            echo "<h3>Pod Activo: $POD_NAME</h3>" >> /www/index.html
            echo "<h3>IP del Pod: $POD_IP</h3>" >> /www/index.html
            echo "<h3>Nodo Host: $NODE_NAME</h3>" >> /www/index.html
            echo "<h3>Hora Actual: $(date)</h3>" >> /www/index.html
            echo "</body></html>" >> /www/index.html
            sleep 2
          done &
          httpd -f -p 8080 -h /www
        ports:
        - containerPort: 8080
        readinessProbe:
          httpGet:
            path: /
            port: 8080
          periodSeconds: 2
          failureThreshold: 1
EOF

cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: k8s-ha-demo-svc
  namespace: kubernetes-ha-demo
spec:
  type: NodePort
  selector:
    app: k8s-ha-demo
  ports:
  - port: 80
    targetPort: 8080
    nodePort: 30082
EOF

# Abrir en browser: http://IP-DE-CUALQUIER-WORKER:30082

kubectl -n kubernetes-ha-demo get pods -o wide
watch -n1 "kubectl -n kubernetes-ha-demo get pods -o wide && kubectl get nodes"

# Para limpiar la prueba:
# kubectl -n kubernetes-ha-demo delete svc k8s-ha-demo-svc
# kubectl -n kubernetes-ha-demo delete deploy k8s-ha-demo
# kubectl delete ns kubernetes-ha-demo
```

---

## 8. Drain de nodos

> Ejecutar desde el Control Plane antes de mantenimiento o reset de un nodo específico.

```bash
# CORDON: evita nuevos pods, sin mover los existentes
kubectl cordon ${HOSTNAME_WORKER_01}
# kubectl uncordon ${HOSTNAME_WORKER_01}

# DRAIN: expulsa todos los pods del nodo
kubectl drain ${HOSTNAME_WORKER_01} --ignore-daemonsets --delete-emptydir-data --force
```

---

## 9. Upgrade de Kubernetes

> Ejecutar en todos los nodos (Managers y Workers).

```bash
dnf clean all
dnf makecache
dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes

kubelet --version
kubeadm version
kubectl version --client

kubeadm config images pull --kubernetes-version ${KUBERNETES_VERSION}.0 --v=5
```

---

## 10. Reset manual del clúster Kubernetes

> **DESTRUCTIVO**. Usar solo para reinicialización total sin migración de red.  
> Para migración de red usar **§1** (`03-teardown-servers.sh`), que hace esto de forma ordenada y segura por rol.

```bash
# Primero hacer drain desde el Control Plane (ver §8)

kubeadm reset -f

rm -rf \
  /etc/cni \
  /etc/kubernetes \
  /var/lib/dockershim \
  /var/lib/etcd \
  /var/lib/kubelet \
  /var/run/kubernetes \
  ~/.kube/*

# Limpieza de reglas iptables
iptables -F && iptables -X
iptables -t nat -F && iptables -t nat -X
iptables -t raw -F && iptables -t raw -X
iptables -t mangle -F && iptables -t mangle -X

# Reinicio de servicios base
systemctl daemon-reload
systemctl restart containerd
systemctl restart kubelet
```

---

## 11. Gestión de Imágenes y Rate Limit de Docker Hub

### 11.1 El problema: Rate Limit de Docker Hub

Docker Hub limita las descargas de imágenes a usuarios no autenticados:

- **Límite anónimo:** 100 pulls cada 6 horas
- **Límite autenticado (cuenta gratuita):** 200 pulls cada 6 horas
- **Síntoma del error:**
  ```
  Error: ImagePullBackOff
  toomanyrequests: You have reached your unauthenticated pull rate limit.
  https://www.docker.com/increase-rate-limit
  ```

### 11.2 Solución 1: Pre-pull de imágenes (Recomendado)

Las imágenes necesarias para el arranque base deben descargarse en caché local antes de la instalación para evitar topar el límite:

```bash
# Ejemplo de pull manual containerd
ctr -n k8s.io images pull registry.k8s.io/kube-apiserver:v${KUBERNETES_VERSION}
```

### 11.3 Solución 2: Autenticación con Token de Docker Hub (containerd v2.x)

> **IMPORTANTE:** Esta configuración debe ejecutarse en **TODOS los nodos MANAGER y WORKER** del cluster. Los nodos BALANCEADOR no tienen containerd y no requieren esta configuración.  
> **NOTA:** Esta es la solución definitiva para containerd v2.x. Los métodos antiguos de hosts.toml con auth no funcionan en esta versión.

#### Paso 1: Generar Token en Docker Hub

1. Ir a https://hub.docker.com/settings/security
2. Clic en "New Personal Access Token (PAT)"
3. Definir descripción: "Cluster K8s HA Pre-prod"
4. Seleccionar permisos "Read Only"
5. Copiar el token generado (solo se muestra una vez)

#### Paso 2: Configuración definitiva en containerd v2.x

Ejecutar en **todos los nodos MANAGER y WORKER**:

**2.1. Verificar versión de containerd:**
```bash
containerd --version
```

**2.2. Crear estructura de directorios:**
```bash
mkdir -p /etc/containerd/certs.d/docker.io
```

**2.3. Crear hosts.toml básico:**
```bash
cat > /etc/containerd/certs.d/docker.io/hosts.toml << 'EOF'
server = "https://docker.io"

[host."https://registry-1.docker.io"]
  capabilities = ["pull", "resolve"]
EOF

chmod 600 /etc/containerd/certs.d/docker.io/hosts.toml
```

**2.4. Modificar config.toml:**

> **CRÍTICO:** Usar `registry-1.docker.io` (NO solo `docker.io`) y tener `version = 2` al inicio del archivo.

```bash
sed -i '/^version = /d' /etc/containerd/config.toml
sed -i '1i version = 2' /etc/containerd/config.toml

cat >> /etc/containerd/config.toml << 'EOF'

[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "/etc/containerd/certs.d"

[plugins."io.containerd.grpc.v1.cri".registry.configs."registry-1.docker.io".auth]
  username = "TU_USUARIO_DOCKER_HUB"
  password = "TU_TOKEN_GENERADO"
EOF

# Reemplazar con valores reales
sed -i 's|TU_USUARIO_DOCKER_HUB|<tu-usuario>|g' /etc/containerd/config.toml
sed -i 's|TU_TOKEN_GENERADO|<tu-token>|g' /etc/containerd/config.toml
```

**2.5. Reiniciar containerd:**
```bash
systemctl restart containerd

# Verificar
crictl pull docker.io/library/busybox:1.36
```

**Troubleshooting:**

| Problema | Solución |
|----------|----------|
| Error `text/html` | Verificar `version = 2` y URL `registry-1.docker.io` |
| Funciona en laptop pero no en workers | Revisar la config en los workers |
| Rate limit sigue apareciendo | El token tiene su propio rate limit — esperar 6 horas |

### 11.4 Solución 3: Usar mirrors alternativos

| Imagen | Alternativo recomendado |
|--------|------------------------|
| `docker.io/library/busybox` | `gcr.io/google-containers/busybox` |
| `docker.io/library/alpine` | `registry.k8s.io/pause` |
| Imágenes Kubernetes | `registry.k8s.io` (ya configurado por defecto) |
| Calico | `quay.io/calico/` (ya en uso) |

---

## 12. Escenarios HA — Doble VIP vs VIP única

En ambientes de alta disponibilidad se pueden configurar dos VIPs:

- `VIRTUAL_IP_K8S` para API Server Kubernetes (`:6443`)
- `VIRTUAL_IP_INGRESS` para tráfico de usuarios (`:80`/`:443`)

### 12.1 Ventajas prácticas de usar doble VIP

1. Aislamiento de tráfico de administración (`kubectl`) vs tráfico de negocio (usuarios).
2. Menor riesgo operativo: cambios de Ingress no impactan directamente el endpoint del API Server.
3. Mejor troubleshooting: se identifica más rápido si la falla es control plane o capa de ingreso.
4. Políticas de seguridad más limpias (ACL/firewall/WAF por VIP).
5. Failover más predecible cuando Keepalived maneja dos servicios lógicos distintos.

### 12.2 Tabla de escenarios

| Diseño | Evento | VIP K8S (`:6443`) | VIP Ingress (`:80/:443`) | Impacto esperado |
|---|---|---|---|---|
| Doble VIP | Falla `haproxy02` (BACKUP) | Permanece en `haproxy01` | Permanece en `haproxy01` | Sin impacto funcional relevante |
| Doble VIP | Falla `haproxy01` (MASTER) | Migra a `haproxy02` | Migra a `haproxy02` | Corte breve durante failover |
| Doble VIP | Caída de 1 master | HAProxy lo marca DOWN, usa otros | Sin efecto directo | `kubectl` sigue si hay masters UP |
| Doble VIP | Caída total de masters API | VIP responde en HAProxy, sin backend | Sin efecto en VIP Ingress | `kubectl` falla |
| Doble VIP | Caída total de ambos HAProxy | No hay endpoint activo | No hay endpoint activo | Falla total de acceso externo |
| VIP única | Falla `haproxy02` (BACKUP) | Permanece en `haproxy01` | Permanece en `haproxy01` | Sin impacto relevante |
| VIP única | Falla `haproxy01` (MASTER) | VIP migra a `haproxy02` | VIP migra a `haproxy02` | Corte breve durante failover |
| ⚠️ No recomendado: 2 VRRP con misma IP | Failover | Inestabilidad ARP/MAC | Flapping intermitente | Síntomas aleatorios |

> **Regla de oro:**  
> - Si usarás doble instancia VRRP (`VI_K8S` y `VI_INGRESS`), usa **dos IPs distintas**.  
> - Si el cliente exige una sola IP, usa diseño de **VIP única** con una sola instancia VRRP.  

---

**Diseño y Automatización:**  
Ing. Jesús A. Chávez Becerra | DevSecOps, Cloud and Infrastructure Architect  
Empresa: **DevSecOps Group S.A.C.**  
*Mayo 2026 — Kubernetes On-Premise HA Pre-Prod Installation Process*
