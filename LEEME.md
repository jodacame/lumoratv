# LumoraTV

🌐 **Español** · [English](README.md)

<p align="center">
  <img src="docs/screenshots/02-home-top10.png" alt="LumoraTV — un home cinematográfico de nivel streaming, en Apple TV" width="100%">
  <br>
  <sub><i>Solo con fines ilustrativos — metadata de muestra de TMDB en un simulador de tvOS.</i></sub>
</p>

### 🤖 Una app premium completa para Apple TV. Escrita por IA. Cero líneas de código humano.

**LumoraTV es un cliente de streaming premium y cinematográfico para Apple TV (tvOS) — un home
cinematográfico, un reproductor de nivel escritorio, un motor de recomendaciones, perfiles
multi-usuario — y cada una de sus líneas fue construida por los modelos frontera de Anthropic,
dirigidos por un humano que jamás tocó el código.**

Esto no es una demo, ni un prototipo, ni un experimento de generación de código que alguien
limpió después. Es un **producto de consumo con calidad de lanzamiento corriendo en hardware
real**, y existe para documentar un punto de inflexión: **el momento en que construir software
real dejó de requerir que un humano lo escribiera.**

> ⚡ **~26 horas** de colaboración real · **169** interacciones humano↔IA ·
> **1,500+** acciones de ingeniería autónomas · **~15,000** líneas de Swift 6 en **53**
> archivos · **~3.85 millones** de tokens de salida pura · **cero** líneas de código escritas
> por un humano.

LumoraTV es agnóstico al servicio: presenta una interfaz unificada y hermosa sobre cualquier
fuente de medios que conectes, con un reproductor real libmpv/FFmpeg, estado por usuario, motor
de recomendaciones, control parental y localización completa inglés/español.

---

## Tabla de contenidos

- [El experimento](#el-experimento)
- [Por qué existe — una nota del humano](#por-qué-existe--una-nota-del-humano)
- [Los números](#los-números)
- [Una nueva forma de construir productos](#una-nueva-forma-de-construir-productos)
- [Características](#características)
- [Cómo funciona](#cómo-funciona)
- [Requisitos](#requisitos)
- [Instalación y despliegue](#instalación-y-despliegue)
- [Primer arranque (onboarding)](#primer-arranque-onboarding)
- [Fuentes externas opcionales](#fuentes-externas-opcionales)
- [Privacidad](#privacidad)
- [Servicios referenciados y disclaimers](#servicios-referenciados-y-disclaimers)
- [Independencia y marcas](#independencia-y-marcas)
- [Licencia](#licencia)
- [Software de terceros](#software-de-terceros)
- [Contribuir](#contribuir)

---

## El experimento

Todo empezó con una pregunta:

> *¿Puede la IA frontera de hoy construir una app de consumo premium que se sienta
> **terminada** — no un juguete, no un esqueleto, no una demo de fin de semana — trabajando
> únicamente con dirección en lenguaje natural?*

La respuesta es este repositorio. **El 100% del diseño, la arquitectura, el código, el
debugging, los refactors y la documentación fue producido por IA** — **Claude Fable 5**, el
modelo frontera más nuevo de Anthropic, junto con **Claude Opus 4.8** — actuando como único
ingeniero. El rol humano fue estrictamente de **asistencia**: visión de producto, criterio,
pruebas en un Apple TV físico y feedback. **Ninguna línea de código fue escrita a mano por una
persona. Ni una.**

Y esto no es un CRUD con buena pintura. Los modelos resolvieron, sin asistencia, lo que
normalmente se considera ingeniería *dura*:

- Integrar **libmpv/FFmpeg con un pipeline de render Metal** (gpu-next vía MoltenVK) en tvOS,
  con decodificación por hardware VideoToolbox y manejo de colorspace HDR10 / Dolby Vision.
- **Swift 6 con strict concurrency** en todo el codebase — el modelo de concurrencia más nuevo
  y exigente del ecosistema, compilando limpio.
- Una **arquitectura de reproducción agnóstica al servicio** que resuelve y fusiona contenido
  de múltiples backends detrás de una única UI premium.
- Una **base de datos local con 11 migraciones de esquema**, un motor de sincronización
  incremental con reconciliación, caché de imágenes con purga LRU y un sistema de estado por
  usuario.
- Toda la **coreografía del focus engine de tvOS** — la parte del desarrollo para TV que los
  veteranos describen como la más implacable.
- Su propio **sistema de localización bilingüe**, un motor de recomendaciones híbrido, control
  parental, y el pipeline de build en sí (sin el IDE de Xcode — todo se genera y compila desde
  la línea de comandos).

> **Los roles, dicho claramente:** IA (Claude Fable 5 y Claude Opus 4.8) — 100% del diseño, la
> ingeniería, el código, el debugging y la documentación. Humano ([Jose Canchila](AUTHORS)) —
> visión de producto, pruebas en dispositivo y feedback. El modelo es el ingeniero. El humano
> es el director y el tester.

## Por qué existe — una nota del humano

Soy desarrollador de software con **más de 20 años de experiencia profesional**. Llevo
escribiendo código más tiempo del que existen algunas de mis herramientas. No necesitaba que
una IA me construyera esta app — **necesitaba saber, de primera mano, exactamente hasta dónde
llega la generación actual de modelos.**

Así que planteé la prueba más difícil que cupiera en mi sala: una app premium completa para
tvOS — una plataforma con un focus engine brutal, un toolchain de nicho, strict concurrency y
hardware real en el circuito — construida **de punta a punta por el modelo**, conmigo actuando
solo como director de producto y tester. Deliberadamente escribí cero código. Cada bug volvió
al modelo en lenguaje natural. Cada arreglo regresó como un diff que jamás edité.

Después de dos décadas escribiendo software a mano, ver a un modelo adueñarse de un codebase
completo — decisiones de arquitectura, sesiones de debugging espinosas, trabajo de rendimiento,
pulido — y entregar algo que estaría orgulloso de lanzar, es lo más cercano a un cambio de
paradigma que he vivido en mi carrera. Este repositorio es mi evidencia, y mi forma de
compartirla.

## Los números

Todo lo de abajo fue medido de los registros reales de la sesión — nada es estimado.

| Métrica | Valor |
|---|---|
| Ingeniería hecha por IA | **100%** — cero líneas de código humano |
| Modelos | **Claude Fable 5** y **Claude Opus 4.8** (Anthropic) |
| Tiempo total de construcción | **~26 horas** de colaboración |
| Interacciones humano ↔ modelo | **169** turnos de conversación |
| Acciones de ingeniería autónomas | **1,504** (builds, ediciones, instalaciones, debugging) |
| Tokens de salida generados | **~3.85 millones** (Fable 5: ~1.74M · Opus 4.8: ~2.11M) |
| Tokens procesados en total (incl. caché de contexto) | **~1.44 mil millones** |
| Archivos fuente | **53 archivos Swift** |
| Líneas de código | **~14,900** (Swift 6, strict concurrency) |
| Estimación humana para el mismo alcance, en solitario | **meses** — aquí, ~26 horas |

## Una nueva forma de construir productos

Este proyecto demuestra un flujo de trabajo que simplemente no existía hace poco:

1. **El humano describe la intención** — en lenguaje natural, muchas veces dictado: *"la
   tarjeta del hero debe revelar la sinopsis al enfocarla"*, *"continuar viendo debe reusar la
   misma fuente"*.
2. **El modelo hace la ingeniería** — lee el codebase, toma decisiones de arquitectura, escribe
   el código, regenera el proyecto, lo compila y lo instala **él solo en el Apple TV físico**.
3. **El humano prueba desde el sofá, control en mano** — y reporta en segundos: *"el foco se
   queda atrapado en el panel de filtros"*.
4. **Repetir.** 169 veces. ~26 horas después: un producto terminado.

Sin tickets, sin specs, sin handoffs, sin sesiones de boilerplate. El ciclo de iteración se
colapsa a la velocidad de una conversación. **El cuello de botella ya no es escribir software —
es decidir qué debe ser el software.**

**Un hallazgo honesto del experimento:** este flujo de trabajo *no* significa que cualquiera
pueda construir cualquier cosa todavía. Algo quedó claro a lo largo de 169 interacciones —
**aún se requiere una base de conocimiento en tecnología, desarrollo de software y diseño**
para hacer las solicitudes *correctas*: describir una característica en términos que el modelo
pueda construir correctamente, reconocer cuándo un flujo puede mejorarse y articular cómo, y
reportar un bug con la precisión suficiente para que pueda diagnosticarse y corregirse. El
modelo elimina la necesidad de *escribir* la solución; no elimina (todavía) la necesidad de
*entender* el problema. La calidad de la dirección es lo que convierte la potencia bruta del
modelo en un producto terminado.

---

## Características

La vara de diseño se puso contra las mejores apps de sala — motion y focus fluidos, un home
denso con filas inteligentes, y una estética cinematográfica — y luego se empujó más allá.
Esta es la lista completa; nada de esto es un mockup, todo
corre en un Apple TV real.

### 🎬 Un home que se siente vivo
- **Hero cinematográfico** con arte a pantalla completa, logos oficiales y degradados — enfoca
  una tarjeta y la sinopsis corta se revela en el lugar.
- **Filas inteligentes**: Continuar Viendo (con barras de progreso en vivo), Tendencias
  (tarjetas horizontales gigantes con backdrop e información integrada), En Cines y
  Próximamente — cada fila con su **propio diseño visual**, no un carrusel clonado.
- **Navegación por categorías** con backdrops únicos, sin repeticiones, por categoría.
- **"Para ti"** — una fila personalizada calculada por usuario, justo debajo de las categorías
  junto a **Mi Lista**.
- **Filosofía cero-spinners**: el contenido se precachea y renderiza antes de que llegues,
  siempre que sea físicamente posible.

### 🧠 Recomendaciones que de verdad te conocen
- Un **motor de recomendaciones híbrido**: tu perfil de gustos local (géneros, reparto,
  me gusta/no me gusta, historial) combinado con **inteligencia de metadata sobre el catálogo
  completo** para aciertos de alta precisión.
- **"Más como esto"** calculado contra el catálogo completo de metadata, no solo lo que posees.
- Las señales de **me gusta / no me gusta** retroalimentan cada fila, por usuario.
- Recomendaciones, búsqueda, grids y similares pasan todos por el **filtro parental** por
  usuario.

### 📺 Un reproductor que la mayoría de apps comerciales no puede igualar
- **libmpv / FFmpeg** renderizado por **Metal** (gpu-next vía MoltenVK) — el mismo motor en el
  que confían los entusiastas en escritorio, corriendo nativo en tvOS.
- **Reproducción directa de prácticamente todo**: MKV, HEVC, AV1, remuxes de alto bitrate —
  sin transcodificación del servidor.
- **HDR10, HLG y reshaping de Dolby Vision** con hinting de colorspace correcto, más
  decodificación por hardware vía VideoToolbox. **Badges de HDR** por versión en la UI.
- Audio **LPCM multicanal 5.1 / 7.1** y passthrough experimental.
- **Saltar intro / saltar créditos**, **siguiente episodio inteligente** consciente de los
  créditos con tarjeta de cuenta regresiva, y un **navegador de episodios dentro del player**
  (temporadas, miniaturas, estado de visto) sin salir de la reproducción.
- **Seek acumulativo con miniaturas de previsualización** (BIF), superficie de foco invisible
  estilo Apple TV, y panel superior de Info / Audio / Subtítulos / Ajustes.
- **Información en pantalla configurable**: reloj, fecha, clasificación, géneros, puntuación,
  año, calidad, pista de audio y subtítulo actuales — cada elemento activable.
- **Modos de imagen cinematográficos** — Normal, Dormir (atenuado/desaturado para la noche),
  Vívido (color más intenso) y **Noir** (blanco y negro) — globales, persistentes, conmutables
  desde el panel del reproductor y desde Ajustes, con un badge en pantalla cuando hay un modo
  no predeterminado activo.
- **Coincidencia de frame-rate con el contenido**: la frecuencia de la pantalla cambia a la
  cadencia nativa del video (24/25/30/50/60) para un movimiento sin judder (vía
  AVDisplayManager), consciente del HDR.
- **Stats para nerds**: una capa técnica en vivo opcional (resolución, códecs, bitrate, frames
  perdidos, caché, conexión) para diagnosticar la reproducción.
- **Estados de buffering adaptativos** con detalle en vivo (conexión, velocidad, pares,
  porcentaje) y un watchdog anti-congelamiento que se recupera u ofrece alternativas en vez de
  quedarse pegado.
- El protector de pantalla y el idle timer se suprimen correctamente durante la reproducción.

### 💬 Subtítulos y audio bien hechos
- **Soporte de subtítulos externos** con **detección automática de idioma** (análisis de
  lenguaje natural en el dispositivo) cuando las pistas llegan sin etiquetar.
- **Integración con OpenSubtitles** para traer subtítulos faltantes.
- Control total de estilo: **tamaño, fuente y color**, por preferencia de usuario, en vivo.
- El idioma preferido de audio/subtítulos se aplica automáticamente en cada reproducción.
- **Memoria de audio y subtítulo por contenido**: el audio y el subtítulo que elegiste se
  recuerdan por título (y se mantienen durante una maratón de serie) y se restauran solos al
  reanudar — incluso para **pistas embebidas sin etiqueta**, emparejadas por posición cuando no
  hay idioma.

### 🗣️ Aprende un idioma mientras ves — una función que nadie más tiene
- Convierte cualquier película o serie en un **tutor de idiomas pasivo**. Mira con subtítulos
  en el idioma que aprendes y la app **resalta discretamente las palabras nuevas** para ti y
  registra tu vocabulario sobre la marcha — **la propia película se vuelve tu sistema de
  repetición espaciada** (una palabra pasa a "conocida" tras suficientes encuentros en
  pantalla).
- **Sin interacción mientras ves** — el aprendizaje ocurre en segundo plano sin alterar la
  experiencia.
- **Repaso bajo demanda**: pausa y el reproductor ofrece un panel *"¿qué acaban de decir?"* —
  repasa las líneas recientes, repítelas, escúchalas en voz alta (texto a voz en el
  dispositivo) y obtén una explicación tipo profesor.
- Modelo de vocabulario **100% en el dispositivo** (framework Natural Language de Apple), por
  usuario, sin backend. Se activa desde el panel del reproductor o Ajustes.

### ✨ Un tutor de idiomas con IA integrado — trae tu propio proveedor
- Una pestaña **Inteligencia Artificial** en Ajustes que funciona con **cualquier proveedor
  compatible con OpenAI**: OpenAI, Anthropic (Claude), Google Gemini, Groq, OpenRouter o un
  modelo local (Ollama / LM Studio).
- Ingresa tu key y **valídala listando los modelos a los que realmente tienes acceso** — sin
  campo libre a ciegas — y elige uno.
- Selecciona una línea de subtítulo y la IA **explica la línea completa** (significado y uso)
  usando las líneas vecinas como contexto, **respondiendo de forma corta en tu idioma de
  subtítulos preferido**, como un profesor. La explicación tiene scroll y un **caché acotado**
  para que no llene el disco; un tip recomienda un modelo económico para aprender.

### 🗂 Una biblioteca sin límites
- **Catálogo multi-servidor fusionado**: el mismo título en varios servidores se funde en una
  sola entrada; el **selector de versiones** aparece solo cuando importa, con badges de
  calidad/HDR por versión.
- **Speed test por servidor** integrado en Ajustes para saber exactamente qué aguanta tu red.
- **Inteligencia de series**: temporadas y episodios con estado de visto, **detección de
  episodios faltantes** contra conteos autoritativos, y un Play que arranca automáticamente en
  el **primer episodio no visto**.
- **Top 10 de hoy**, **filas de colección / saga** que agrupan una franquicia, **alertas de
  nuevos episodios** de las series que ves, y **reanudación inteligente** que retoma justo
  donde quedaste.
- **Metadata premium**: pósters, logos oficiales, backdrops, sinopsis y reparto —
  re-descargados y **re-localizados al cambiar el idioma de la app**.
- **Vista de Personas**: salta de cualquier título a su reparto y navega todo por actor o
  director.
- **Búsqueda** con historial reciente, sobre tu biblioteca y el catálogo extendido.
- **Tráiler para todo**: cuando no hay tráiler disponible, la app reproduce una
  previsualización de 15 segundos del propio título — sin botones muertos.

### 🔌 Agnóstico al servicio hasta el núcleo
- Toda la app está construida sobre un modelo abstracto de **fuente**: cualquier backend que
  pueda resolver una entrada de catálogo y una URL reproducible recibe **exactamente la misma
  UI premium** — misma pantalla de detalle, mismas tarjetas, mismo player.
- **Selector de fuentes** como modal cinematográfico con fondo difuminado y **chips de filtro
  por proveedor**; **cambio de fuente en plena reproducción** desde el player, y el overlay de
  error ofrece fuentes alternativas en vez de un callejón sin salida.
- Modo **auto-mejor-fuente**: un solo Play y la app elige la versión óptima por ti, con un
  **ranking compuesto** (calidad, salud del enjambre, idiomas configurados, tamaño razonable,
  freeleech) y **failover automático**: si la mejor fuente no arranca, pasa a la siguiente con
  aviso en pantalla.
- **Smart Data — un ranking que aprende viéndote ver**: la app aprende de tu comportamiento
  real — qué indexers cargan y se terminan, y qué *uploaders* (release groups) publican
  archivos que ves completos **con sus subtítulos embebidos puestos** (la verdad no es lo que
  el título promete, sino que termines la película con esos subs activos; descargar subtítulos
  externos a mitad cuenta en contra). Todo visible en **Ajustes → Smart Data**: barras de
  reputación por indexer y uploader, con botón de reinicio. Contadores con suavizado
  bayesiano, locales al dispositivo, cero telemetría.
- **Badges de origen local / remoto** en cada tipo de tarjeta, para que siempre sepas dónde
  vive el contenido.
- Un **Modo Streaming opcional, apagado por defecto**, extiende la navegación a un catálogo
  completo guiado por metadata con grids paginados y un **panel de filtros** profesional
  (género, año, clasificación, orden) diseñado para manejar decenas de miles de títulos.

### 👨‍👩‍👧 Multi-usuario de verdad
- **Todo por usuario**: progreso, Continuar Viendo, Mi Lista, me gusta/no me gusta, búsquedas
  recientes — ligado a la identidad del usuario activo del Apple TV.
- **Control parental por usuario**: PIN más clasificación máxima, aplicado en home, grids,
  búsqueda, recomendaciones y similares.
- **Sincronización entre dispositivos (con iCloud)**: con una cuenta de pago de Apple
  Developer, tu progreso, Mi Lista, valoraciones, preferencias, vocabulario aprendido, control
  parental y los subtítulos que elegiste/descargaste se sincronizan **por usuario** entre todos
  tus Apple TV a través de tu iCloud privado — **cifrado de extremo a extremo** en las partes
  sensibles (Apple solo ve texto cifrado). Los subtítulos descargados "te siguen" por
  referencia (la app los vuelve a traer en la otra TV). Sin iCloud, todo queda **100% local** y
  nada cambia.
- El progreso se reporta a un backend **solo** cuando el contenido se está reproduciendo desde
  ese backend; todo lo demás queda local y privado.

### ✨ Usabilidad y oficio
- **Onboarding guiado** pensado para usuarios no técnicos: vinculación automática de cuenta con
  un código corto y **código QR** — sin teclear en la TV si no quieres.
- **Focus engine de nivel Apple**: efectos de foco con escala + glow, motion `.smooth` en toda
  la app, tipografía grande y redondeada, y navegación por foco que nunca te atrapa.
- **Menú contextual con pulsación larga** en cada tarjeta (reproducir, Mi Lista, me gusta/no me
  gusta, ir al detalle).
- **Deep links** (`lumoratv://`) listos para Top Shelf e integración externa.
- **Dos idiomas, de primera clase**: localización completa inglés y español — UI *y* metadata.
- **Test de conexión por servicio** en Ajustes, con diagnóstico claro de éxito/fallo.
- **Persistencia local-first** (SQLite vía GRDB), **sync incremental con reconciliación**,
  caché de respuestas de metadata, y **caché de imágenes con límite configurable y purga LRU**.
- Manejo robusto de errores de red: mensajes claros, rutas de reintento, nunca un cuelgue
  silencioso.

---

## Cómo funciona

LumoraTV está construido alrededor de la noción abstracta de **fuente**. La pantalla de
detalle, las filas del catálogo y la UI de reproducción no saben de dónde viene el contenido:
un servidor de medios auto-alojado, un catálogo externo guiado por metadata o un backend futuro
fluyen por los mismos componentes. Al presionar Play, un resolutor reúne todas las versiones
disponibles entre tus fuentes configuradas y reproduce la mejor o te deja elegir.

- **Catálogo**: tu servidor de medios auto-alojado (la app está construida y probada con Plex
  como backend de referencia) aporta tu biblioteca real; un proveedor de metadata la enriquece
  con arte y recomendaciones.
- **Reproducción**: un player unificado reproduce la URL que el resolutor devuelva.
- **Estado**: progreso, listas y votos viven localmente, por usuario. El progreso solo se
  reporta a un backend cuando el contenido se está reproduciendo *desde* ese backend.

Este diseño es lo que hace a la app extensible a más tipos de servidores en el futuro.

---

## Requisitos

**Hardware**
- Un **Apple TV 4K** (2ª generación o posterior recomendado), con **tvOS 26** o superior, en
  modo desarrollador y emparejado con tu Mac.

**Máquina de build**
- **macOS** con el toolchain de **Xcode** instalado.
- [**XcodeGen**](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- Una **cuenta de Apple Developer** — la gratuita funciona (con limitaciones, ver abajo); la de
  pago las elimina.

**Backends que tú aportas**
- Un **servidor de medios auto-alojado** en tu red (Plex es el backend de referencia).
- Una **clave de API de metadata** gratuita ([TMDB](https://www.themoviedb.org/settings/api)),
  que se ingresa en el onboarding — necesaria para el arte premium y las recomendaciones.
- *(Opcional)* fuentes externas — ver [Fuentes externas opcionales](#fuentes-externas-opcionales).

> **Limitaciones de la cuenta gratuita de Apple:** los perfiles de aprovisionamiento vencen
> cada **7 días**, así que debes re-compilar y re-instalar semanalmente. Una cuenta de pago
> ($99/año) elimina ese límite y desbloquea perfiles por usuario y Top Shelf.

---

## Instalación y despliegue

Este proyecto se **compila completamente desde la línea de comandos** — el proyecto de Xcode se
genera desde `project.yml` con XcodeGen y nunca debe editarse a mano.

```sh
# 1. Clona el repositorio, abre project.yml y pon tu DEVELOPMENT_TEAM
#    (tu team ID personal de Apple).

# 2. Genera el proyecto de Xcode desde project.yml
xcodegen generate

# 3. Compila firmado para el dispositivo
xcodebuild -project LumoraTV.xcodeproj -scheme LumoraTV \
  -destination 'generic/platform=tvOS' -allowProvisioningUpdates build

# 4. Encuentra el .app compilado
xcodebuild -project LumoraTV.xcodeproj -scheme LumoraTV \
  -destination 'generic/platform=tvOS' -showBuildSettings | grep BUILT_PRODUCTS_DIR

# 5. Instala en tu Apple TV emparejado (reemplaza <UDID> y la ruta)
xcrun devicectl device install app --device <UDID> <BUILT_PRODUCTS_DIR>/LumoraTV.app

# 6. Lánzala
xcrun devicectl device process launch --device <UDID> dev.jodacame.lumoratv
```

**Tips de emparejamiento**
- Encuentra el UDID de tu Apple TV con `xcrun devicectl list devices`.
- Si el dispositivo aparece `unavailable`, despiértalo con el control.
- Si el pareo se cae: en el Apple TV ve a *Ajustes → Mandos y dispositivos → Aplicación Remote
  y dispositivos*, y corre `xcrun devicectl manage pair --device <UDID>`.

Tras cambiar `project.yml` o agregar archivos, corre siempre `xcodegen generate`.

---

## Primer arranque (onboarding)

La app te guía por la configuración con el control (sin teclear donde sea evitable):

1. **Conecta tu servidor de medios** — con el flujo de vinculación automática (recibes un
   código corto, lo confirmas desde tu teléfono y la app encuentra tus servidores), o con la
   configuración manual ingresando IP, puerto y token de acceso directamente.
2. **Metadata premium** — pega tu clave de API gratuita (también puedes hacerlo después en
   Ajustes). Esto habilita pósters, logos y recomendaciones de alta calidad.
3. **Listo** — explora tu biblioteca.

Todos los secretos que ingresas se guardan en el **Keychain** del sistema, nunca en texto
plano.

---

## Fuentes externas opcionales

Bienvenido a la sección que el departamento legal insistió en etiquetar como *"puramente
experimental"*, que la ingeniería describe como *"un cliente delgado sobre HTTP"*, y que tú,
la primera vez que la veas funcionar, vas a describir como **brujería**. ☕

*(Nota: este proyecto no tiene departamento legal. Tiene un disclaimer al final de esta
sección y mucha fe en tu sentido común.)*

Toda biblioteca auto-alojada tiene el mismo techo: tu disco. Terabytes de NAS, años curando
colecciones, y aun así la película que quieres ver esta noche es justo la que no está. El
modo **Streaming** (opcional, **apagado por defecto**) invierte la ecuación: en vez de
navegar *lo que tienes*, navegas **el catálogo completo de metadata — decenas de miles de
títulos, efectivamente infinito** — con las mismas filas premium, el mismo detalle, el mismo
player… y el contenido se resuelve **on demand, en el momento del Play, sin almacenar
absolutamente nada**.

Sin discos llenos de medios. Sin esperar descargas. Sin biblioteca que mantener. Le das Play a
algo que no posees, y segundos después está reproduciéndose en tu Apple TV como si siempre
hubiera estado ahí. La primera vez que funciona, francamente, da un poco de risa nerviosa: una
videoteca infinita servida por una cajita que consume menos que el LED del televisor.

¿La trampa? *(Siempre hay una.)* La app no hace magia sola — es un **cliente delgado**. El
trabajo sucio lo hacen dos servicios que **tú** montas en cualquier máquina siempre encendida
de tu red (un mini-PC, una Raspberry Pi, ese portátil viejo del cajón — un NAS sirve, pero ya
no lo *necesitas* para nada más que esto):

| Pieza | Qué hace | Qué necesitas |
|---|---|---|
| [Prowlarr](https://prowlarr.com) | El buscador: encuentra *releases* de un título entre los indexadores que tú configures. | Instalarlo, agregarle indexadores, y pegar su URL + API key en Ajustes → Modo Streaming. |
| [TorrServer](https://github.com/YouROK/TorrServer) | El puente: convierte un torrent en una URL HTTP reproducible al vuelo, con buffer inteligente. Nada toca el disco del Apple TV. | Instalarlo y pegar su URL en Ajustes → Modo Streaming. Alternativa: [FluxTorrent](https://github.com/jodacame/FluxTorrent), un puente más simple y ligero del mismo autor, compatible con la misma configuración. |
| Clave de [TMDB](https://www.themoviedb.org) | El catálogo "infinito" que navegas. | La misma clave gratuita del onboarding. |

Con las tres piezas configuradas, activas el interruptor de Modo Streaming (que te muestra una
advertencia muy seria que deberías leer de verdad) y el Home se expande: catálogo completo con
filtros profesionales, selección de fuente con filtro por proveedor, packs de temporadas que
reproducen el episodio exacto, "Continuar viendo" que recuerda la fuente original. La app solo
reproduce una URL HTTP; no descarga, no indexa y no almacena nada.

> ⚠️ **Aviso legal (la parte sin sarcasmo).** Esto es **tecnología de doble uso**. Viene
> desactivada por defecto y detrás de un interruptor explícito con advertencia. **Tú eres el
> único responsable** de lo que indexas, transmites o accedes a través de cualquier fuente que
> conectes, y de cumplir las leyes y derechos aplicables en tu jurisdicción. Los autores
> ofrecen esta función solo para usos legítimos (p. ej., tu propio contenido) y **no avalan ni
> toleran la infracción de derechos de autor**. Úsala bajo tu propio riesgo.

---

## Privacidad

LumoraTV es un cliente **local-first**:

- **No recolecta analytics** y **no envía telemetría** a los autores.
- Se conecta **solo** a los servidores y servicios que **tú** configuras.
- Todas las credenciales (tokens, claves de API) se guardan en el **Keychain** del dispositivo.
- El progreso, las listas y los votos se guardan **localmente** en el dispositivo.

---

## Servicios referenciados y disclaimers

LumoraTV puede interoperar con los siguientes servicios de terceros. **Ninguno viene incluido,
preconfigurado ni es obligatorio más allá de lo que tú decidas configurar.** Cada uno es un
producto independiente de su respectivo dueño:

| Servicio | Para qué lo usa LumoraTV | Disclaimer |
|---|---|---|
| [Plex](https://www.plex.tv) | Backend de referencia de servidor de medios auto-alojado: catálogo, streams, flujo de vinculación de cuenta. | Plex es una marca de Plex, Inc. LumoraTV es un **cliente no oficial e independiente**, sin afiliación, respaldo ni certificación de Plex, Inc. Necesitas tu propio servidor y cuenta de Plex. |
| [TMDB](https://www.themoviedb.org) | Metadata premium: pósters, logos, backdrops, sinopsis, reparto, recomendaciones. | Este producto usa la API de TMDB pero **no está respaldado ni certificado por TMDB**. Debes aportar tu propia clave de API gratuita y cumplir sus [términos de uso](https://www.themoviedb.org/terms-of-use). |
| [Prowlarr](https://prowlarr.com) | *(Opcional, apagado por defecto)* Gestor de indexadores auto-alojado que el Modo Streaming consulta para buscar releases. | Proyecto open source independiente (GPL-3.0). Sin afiliación con LumoraTV. **Tú** lo ejecutas, configuras sus indexadores y eres responsable de lo que indexa. |
| [TorrServer](https://github.com/YouROK/TorrServer) | *(Opcional, apagado por defecto)* Puente torrent→HTTP auto-alojado; LumoraTV solo reproduce la URL HTTP que expone. | Proyecto open source independiente. Sin afiliación con LumoraTV. Corre en **tu** hardware, bajo **tu** responsabilidad — ver el [aviso legal](#fuentes-externas-opcionales). |
| [FluxTorrent](https://github.com/jodacame/FluxTorrent) | *(Opcional, apagado por defecto)* Alternativa a TorrServer del mismo autor: puente torrent→HTTP más simple y ligero. | Proyecto hermano pero independiente. Corre en **tu** hardware, bajo **tu** responsabilidad — aplica el mismo [aviso legal](#fuentes-externas-opcionales). |
| [OpenSubtitles](https://www.opensubtitles.com) | *(Opcional)* Descarga de subtítulos faltantes. | Requiere tu propia cuenta/clave de API y cumplir sus términos. Sin afiliación con LumoraTV. |
| [Trakt](https://trakt.tv) | *(Opcional)* Comentarios y valoraciones de la comunidad en el reproductor; calificar / marcar visto / comentar al enlazar tu cuenta. Configuración: [docs/TRAKT.md](docs/TRAKT.md). | Servicio independiente. Requiere tu propia app de API gratis (Client ID/Secret) y, para escribir, tu login por usuario. Sin afiliación con LumoraTV. |
| [plex.tv/link](https://plex.tv/link) | Flujo de vinculación de dispositivo en el onboarding (código corto / QR). | Parte del servicio de Plex; aplica el mismo disclaimer de arriba. |

Apple, Apple TV, tvOS y Siri Remote son marcas de Apple Inc. LumoraTV no está afiliado,
respaldado ni certificado por Apple Inc.; es una app sideloaded que tú compilas e instalas con
tu propia cuenta de desarrollador.

## Independencia y marcas

LumoraTV es un **proyecto independiente, no comercial y de código abierto** creado para
explorar las capacidades de los modelos de Anthropic. **No está afiliado, respaldado,
patrocinado ni certificado por ninguno de los servicios a los que puede conectarse, ni por
ninguna empresa, producto o marca mencionada en este repositorio.**

Todos los nombres de productos, logos y marcas pertenecen a sus respectivos dueños. Las
referencias a servicios de terceros existen solo para describir interoperabilidad. LumoraTV se
distribuye **sin contenido y sin credenciales** y actúa únicamente como un cliente que **tú**
configuras y ejecutas.

Este producto usa APIs de metadata de terceros pero **no está respaldado ni certificado** por
esos proveedores; sus atribuciones requeridas se muestran dentro de la app y en
[NOTICE](NOTICE).

---

## Licencia

LumoraTV es open source bajo la **Apache License 2.0** — ver [LICENSE](LICENSE).

Puedes usarlo, estudiarlo, modificarlo y redistribuirlo libremente, incluso comercialmente,
siempre que preserves los avisos de copyright, patentes, marcas y atribución, y declares los
cambios significativos que hagas. La licencia incluye una concesión explícita de patentes y
entrega el software **"TAL CUAL", sin garantías de ningún tipo**.

Copyright © 2026 Jose Canchila.

## Software de terceros

LumoraTV se apoya en software open source, cada uno bajo su propia licencia: mpv/libmpv
(LGPL-2.1+), FFmpeg (LGPL-2.1+), libplacebo (LGPL-2.1), libass (ISC), MoltenVK (Apache-2.0),
dav1d (BSD-2-Clause), MPVKit (LGPL-2.1), GRDB.swift (MIT). Si distribuyes binarios que enlazan
los componentes LGPL, debes cumplir la LGPL por tu cuenta. Ver [NOTICE](NOTICE) para el texto
completo de atribuciones.

## Contribuir

Las contribuciones son bienvenidas — ver [CONTRIBUTING.md](CONTRIBUTING.md). Bajo Apache-2.0,
las contribuciones se aceptan bajo la misma licencia del proyecto (inbound = outbound). No se
requiere CLA.
