# Adminer (vendored)

- Archivo: `adminer-6.1.1-mysql.php` (release oficial v6.1.1, solo MySQL/MariaDB, multi-idioma).
- Origen: https://github.com/vrana/adminer/releases/download/v6.1.1/adminer-6.1.1-mysql.php
  (idéntico a https://www.adminer.org/static/download/6.1.1/adminer-6.1.1-mysql.php).
- SHA256: `2d092e713717c8106ae276ca5780b77970d3378817a792c6bc584651d4039cc6`
  (coincide con el digest publicado por GitHub para el asset y con la descarga de adminer.org).
  Adminer no publica firma GPG de los binarios.
- Licencia: Apache 2.0 / GPL 2.
- Fuera de `web/public`: no es accesible por URL; solo lo carga `web/public/sgbd/index.php` tras validar la sesión del panel.
