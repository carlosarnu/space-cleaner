# 🗂️ Space Cleaner

Aplicación de escritorio para **liberar espacio en Windows** revisando tus archivos uno a uno: cada archivo se marcar para **borrar**, **mover a otro disco** o **conservar**, y solo después se ejecuta todo en lote con confirmación.

Interfaz moderna en modo oscuro, servida por un backend local en PowerShell y abierta como ventana de aplicación nativa (sin barra de navegación).

![Interfaz de Space Cleaner con las recomendaciones aplicadas](screenshot.png)

> 📸 Captura de la interfaz con datos de ejemplo: los archivos mostrados son ficticios, no corresponden a ningún equipo real.

---

## ✨ Características

| | |
|---|---|
| 🏷️ **Clasificación automática** | Detecta juegos, cachés, archivos de sistema y carpetas de proyectos en desarrollo |
| 📊 **Panel de discos** | Uso y espacio libre de C: y D: en tiempo real |
| 🔍 **Filtros y búsqueda** | Por pestaña, nombre, ruta, extensión, tamaño o antigüedad |
| ⚡ **Acciones rápidas** | Aplicar recomendaciones, mover todos los juegos, borrar todas las cachés |
| 🛡️ **Protección de sistema** | Bloquea en servidor `pagefile.sys`, `hiberfil.sys` y todo bajo `C:\Windows` |
| ⚠️ **Aviso de proyectos** | Advertencia explícita si vas a tocar una carpeta de proyecto activo |
| 📦 **Movimiento estructurado** | `C:\Users\...\juegos\j.zip` → `D:\Users\...\juegos\j.zip` recreando carpetas |
| 🔙 **Sin sorpresas** | Modal de confirmación con el detalle completo antes de tocar nada |

---

## 📋 Requisitos

- **Windows 10 / 11**
- **PowerShell 5.1** (viene con Windows)
- **Microsoft Edge o Google Chrome** (para la ventana de la app)

No requiere instalación, dependencias ni privilegios de administrador.

---

## 🚀 Uso rápido

### 1. Genera el inventario de archivos

```powershell
powershell -ExecutionPolicy Bypass -File .\escanear.ps1
```

Crea unos CSV en tu **Escritorio** con el inventario de tus archivos (tamaño, fecha y días sin usarse). Opcionalmente limita unidades:

```powershell
.\escanear.ps1 -Drives C:\ -OutDir "$env:USERPROFILE\Desktop"
```

> ⏱️ Escanear un disco completo puede tardar varios minutos.

### 2. Lanza la app

Doble clic en **`iniciar.bat`**

El script arranca el servidor en segundo plano, espera a que esté listo y abre la aplicación en Edge en **modo app**. Si vuelves a ejecutarlo, reutiliza el servidor que ya esté corriendo.

### 3. Decide archivo a archivo

1. Elige la pestaña que te interese.
2. Pulsa **Borrar**, **Mover a D:\\** o **Conservar** en cada tarjeta.
3. Revisa el contador de la barra inferior.
4. Pulsa **Ejecutar Cambios** y confirma en el modal.

---

## 🗂️ Estructura del proyecto

```
space-cleaner/
├── app.html        # Interfaz (HTML + CSS + JS, sin dependencias)
├── server.ps1      # API local: lee CSV, controla discos, borra y mueve
├── iniciar.bat     # Lanzador: arranca servidor + abre ventana Edge
├── escanear.ps1    # Generador del inventario de archivos
├── .gitignore      # Excluye CSV y datos personales
└── README.md
```

---

## 🔌 API local

El servidor escucha solo en `http://localhost:39841/` (nunca expuesto a la red).

| Método | Ruta | Descripción |
|---|---|---|
| `GET` | `/` | Sirve `app.html` |
| `GET` | `/api/disks` | Espacio total/libre de C: y D: |
| `GET` | `/api/files` | Inventario clasificado |
| `GET` | `/api/reveal?path=` | Abre el Explorador en la ruta indicada |
| `POST` | `/api/execute` | Ejecuta `{ actions: [{ path, action }] }` |
| `POST` | `/api/shutdown` | Detiene el servidor |

Acción válida: `delete` o `move`.

---

## 🔒 Seguridad y privacidad

- El servidor solo acepta conexiones **loopback** (`localhost`), no está accesible desde tu red.
- Los archivos de **sistema** se rechazan en el servidor, no solo en la interfaz.
- Los CSV del inventario contienen **rutas y tamaños reales de tu equipo**: por eso están en `.gitignore` y **nunca** se incluyen en el repositorio.
- Este proyecto **no envía nada a internet**: solo habla con tu propio equipo.

---

## 🧪 Verificado

| Prueba | Estado |
|---|---|
| Arranque servidor + ventana de app | ✅ |
| Mover archivo C: → D: (creando estructura) | ✅ |
| Borrar archivo | ✅ |
| Rechazar `pagefile.sys` | ✅ |
| Carpeta de proyecto marcada como protegida | ✅ |

---

## 📄 Licencia

MIT
