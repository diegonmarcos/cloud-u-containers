apiVersion: 1

datasources:
  - name: Loki
    type: loki
    access: proxy
    url: http://localhost:@LOKI_PORT@
    isDefault: true

  - name: Tempo
    type: tempo
    access: proxy
    url: http://localhost:@TEMPO_PORT@

  - name: Mimir
    type: prometheus
    access: proxy
    url: http://localhost:@MIMIR_PORT@/prometheus

  - name: Photoprism MariaDB
    type: mysql
    access: proxy
    url: photoprism-db:3306
    database: photoprism
    user: photoprism
    secureJsonData:
      password: photoprism_db123
