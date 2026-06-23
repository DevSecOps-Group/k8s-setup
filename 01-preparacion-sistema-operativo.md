# 01 — Preparación del Sistema Operativo: Cimientos Sólidos

Como arquitectos de infraestructura, les aseguro que el 80% de los problemas de inestabilidad en un clúster de producción provienen de un sistema operativo mal preparado. Este módulo construye la base sobre la cual correrá todo el stack de Kubernetes.

Para este laboratorio, utilizaremos **Oracle Linux 9.7** equipado con el último **Kernel UEK 7** (Unbreakable Enterprise Kernel Release 7). Este entorno nos proporciona la robustez empresarial necesaria para cargas críticas.

> **Aplica para:** TODOS los nodos (HA-Proxy, Manager y Workers).
> **Pre-requisito:** Todos los comandos asumen que tienes privilegios de administrador. Cambia a root usando `sudo su -`.

---

### 🗺️ Flujo de Preparación del Sistema Operativo

```mermaid
flowchart LR
    classDef step fill:#AEC6CF,stroke:#8FA9B3,stroke-width:2px,color:#333;
    classDef warn fill:#FFD8B1,stroke:#D6B492,stroke-width:2px,color:#333;

    A[1. Validar OS y Kernel]:::step --> B[2. Configurar /etc/hosts]:::step
    B --> C[3. Deshabilitar SWAP]:::step
    C --> D[4. SELinux y Firewalld]:::warn
    D --> E[5. Sincronizar NTP]:::step
    E --> F[6. Instalar Herramientas]:::step
    F --> G[7. Reiniciar]:::warn
```

---

## 1. Validación de Oracle Linux 9.7 y UEK 7

Como buenos ingenieros, validemos nuestro entorno. No asuman nada, siempre verifiquen.

```bash
# Validar la versión del SO (Debería mostrar Oracle Linux 9.7)
cat /etc/oracle-release

# Validar la versión del kernel (UEK 7 generalmente inicia con 5.15.x o superior)
uname -r
```

## 2. Configuración de Resolución de Nombres (`/etc/hosts`)

Kubernetes es un sistema distribuido. Sus componentes (etcd, kube-apiserver, kubelet) necesitan saber quién es quién. Aunque tengan un servidor DNS corporativo, siempre configuren el archivo `/etc/hosts` como método de contingencia. 

Añadan los registros de **todos** sus nodos en **cada uno de los servidores**:

```bash
cat <<EOF >> /etc/hosts
# Clúster Kubernetes On-Premise
192.168.1.10   haproxy-01
192.168.1.20   master-01
192.168.1.31   worker-01
192.168.1.32   worker-02
192.168.1.33   worker-03
EOF
```
*Tip: Eviten usar caracteres especiales en los hostnames. Kubernetes espera nombres de host compatibles con DNS (RFC 1123).*

---

## 3. Desactivar Swap: Incompatibilidad con Kubernetes

Por defecto, Kubernetes no tolera el Swap (memoria de intercambio). ¿La razón? El planificador (`kube-scheduler`) necesita saber exactamente cuánta memoria física real tiene cada nodo para poder asignar los contenedores de forma predecible. Si se usa Swap, el rendimiento cae en picada y los OOMKills (Out Of Memory Kills) se vuelven un misterio.

```bash
# 1. Desactivar el swap que está corriendo ahora mismo
swapoff -a

# 2. Desactivarlo permanentemente para que no reviva al reiniciar
sed -i '/ swap / s/^/#/' /etc/fstab
```

---

## 4. Desactivar SELinux y Firewalld

**SELinux** aplica políticas estrictas sobre lo que los procesos pueden o no pueden hacer. Puesto que los contenedores necesitan montar volúmenes del host y manipular interfaces de red virtual, SELinux a menudo bloquea estos intentos silenciosamente. En instalaciones desde cero, lo apagamos para asegurar que no interfiera.

**Firewalld** choca constantemente con las políticas de red e `iptables` generadas dinámicamente por Kubernetes (a través del componente `kube-proxy` y nuestro CNI). 

```bash
# Desactivar SELinux en caliente
setenforce 0
# Desactivar SELinux permanente
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config

# Apagar y deshabilitar Firewalld
systemctl stop firewalld
systemctl disable firewalld
```

---

## 5. Sincronización de Tiempo (NTP)

El Control Plane de K8s utiliza un almacén de clave-valor llamado `etcd`. Este componente depende de algoritmos de consenso altamente sensibles al tiempo. Además, todos los certificados TLS caducarán erróneamente si los relojes están desfasados. 

```bash
# Configurar su zona horaria (Ajusten según su país)
timedatectl set-timezone America/Lima

# Asegurar que chronyd (servidor NTP de Oracle Linux) esté activo
systemctl enable --now chronyd
```

---

## 6. Herramientas de Trinchera

Vamos a instalar paquetes básicos que nos salvarán la vida a la hora de hacer troubleshooting.

```bash
dnf install -y curl wget vim jq tree git bash-completion net-tools tar iproute-tc
```

> [!IMPORTANT]
> **Reinicio Obligatorio**
> Hemos tocado el núcleo de Linux (Swap y SELinux). Para que el UEK 7 asuma la configuración limpia, ejecuten `reboot` ahora. Continuamos en el módulo 2.
> ```bash
> reboot
> ```

---

**Material Patrocinado por:** DevSecOps Group SAC (Consultoría & Entrenamiento Corporativo)  
**Instructor Certificado:** Ing. Jesús A. Chávez Becerra  
**Contacto:** jesus@devsecops.pe  
