# Booking Platform — команде за покретање

PowerShell, из `infrastructure-service`. Покрећи команде редом; ако команда пријави грешку, стани. Прегледај сваки Terraform план пре `apply`.

Потребно: Azure CLI, Terraform 1.16+, Helm, kubectl, Python 3.10+ и Chrome. За Minikube још Docker Desktop и Minikube. Сачувај локалне Terraform state фајлове; не уписуј state, планове или лозинке у Git.

## Azure deploy — AKS + Azure SQL + Azure DocumentDB

За постојећи кластер и нови image довољни су кораци **1 и 6**. За поновно креирање AKS-а уради све кораке. SQL, DocumentDB и Key Vault су одвојени од AKS-а. Ако SQL и vault још не постоје, после пријаве уради [једнократну припрему](#first-setup). AKS и SQL су у Italy North; бесплатни DocumentDB је у France Central.

### 1. Пријава и зависности

```powershell
cd C:\Users\Bogdan\Desktop\Devops\infrastructure-service
az login
az account set --subscription bff6a774-701a-4987-b913-5288d9ef784e
az account show --query "{Name:name,Subscription:id}" -o table
```

Једном на рачунару и после измене `requirements-smoke.txt`:

```powershell
python -m pip install -r .\scripts\requirements-smoke.txt
```

### 2. AKS

```powershell
terraform "-chdir=infra/azure" init
terraform "-chdir=infra/azure" plan "-var-file=azure-sql.tfvars" "-out=aks.tfplan"
terraform "-chdir=infra/azure" apply "aks.tfplan"
```

### 3. Ingress

```powershell
terraform "-chdir=infra/azure-ingress" init
terraform "-chdir=infra/azure-ingress" plan "-out=ingress.tfplan"
terraform "-chdir=infra/azure-ingress" apply "ingress.tfplan"
```

### 4. Лозинка за SQL Terraform

Кораке 4 и 5 покрени у истом терминалу. Ово није потребно за обичан Helm деплој из корака 6.

```powershell
$env:TF_VAR_administrator_password = az keyvault secret show --vault-name kv-booking-bff6a774 --name sql-admin-password --query value -o tsv --only-show-errors
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($env:TF_VAR_administrator_password)) {
    Remove-Item Env:TF_VAR_administrator_password -ErrorAction SilentlyContinue
    throw 'SQL password was not loaded. Stop here.'
}
```

### 5. SQL firewall — твоја адреса и излазне адресе AKS-а

Понови после поновног креирања AKS-а или промене своје IP адресе. При сваком наредном SQL `plan/apply` проследи цео скуп адреса; празна променљива може уклонити постојећа правила.

```powershell
$sqlClientIp = (Invoke-RestMethod 'https://api.ipify.org').Trim()
$sqlAllowed = @{ operator = $sqlClientIp }
$outboundIds = az aks show --subscription bff6a774-701a-4987-b913-5288d9ef784e -g booking-aks-lab -n booking-aks --query "networkProfile.loadBalancerProfile.effectiveOutboundIPs[].id" -o tsv
if ($LASTEXITCODE -ne 0 -or -not $outboundIds) { throw 'AKS outbound IPs not found.' }
$i = 0
foreach ($id in $outboundIds) {
    $ip = az network public-ip show --ids $id --query ipAddress -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $ip) { throw 'Public IP lookup failed.' }
    $sqlAllowed["aks-$i"] = $ip
    $i++
}
$env:TF_VAR_allowed_ipv4 = $sqlAllowed | ConvertTo-Json -Compress
```

```powershell
terraform "-chdir=infra/azure-sql" init
terraform "-chdir=infra/azure-sql" plan "-out=sql-network.tfplan"
terraform "-chdir=infra/azure-sql" apply "sql-network.tfplan"
Remove-Item Env:TF_VAR_administrator_password -ErrorAction SilentlyContinue
```

### 5а. Azure Mongo — прво креирање и ажурирање firewall-а

Први пут региструј provider:

```powershell
az provider register --namespace Microsoft.DocumentDB --subscription bff6a774-701a-4987-b913-5288d9ef784e --wait
```

У истом терминалу после корака 5 (користи исти `TF_VAR_allowed_ipv4`), покрени и после сваког поновног креирања AKS-а:

```powershell
terraform "-chdir=infra/azure-mongo" init
terraform "-chdir=infra/azure-mongo" plan "-out=mongo.tfplan"
terraform "-chdir=infra/azure-mongo" apply "mongo.tfplan"
terraform "-chdir=infra/azure-mongo" output mongo
```

У плану мора бити `compute_tier = "Free"`; нема преласка на плаћени пакет ако бесплатни није доступан. Terraform једном генерише јаку лозинку од 32 знака, чува је у Key Vault-у као `mongo-azure-admin-password` и уписује connection string у `mongo-conn-search-azure`. Постојећи `mongo-root-password` се не мења. Лозинка остаје иста при наредним покретањима док је Terraform state сачуван. Лозинка и connection string постоје у локалном state-у: не шаљи state/план у Git. Нема ручног копирања лозинке или connection string-а.

Први деплој са `-AzureMongo` уклања стари Mongo под и PVC. Подаци се **не преносе**; претрага почиње празна. Стари SQL смештаји се не индексирају аутоматски — за проверу направи нови смештај и доступност. Minikube задржава локални Mongo.

Free пакет: 32 GB, без уграђеног backup/restore-а; паузира се после 60 дана неактивности. [Microsoft услови](https://learn.microsoft.com/en-us/azure/documentdb/free-tier).

### 6. Деплој апликације и smoke тест

Сачекај да CI објави image-е. `releases/test-01.yaml` тренутно користи `develop` за свих седам компоненти.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Deploy-Azure.ps1 -VersionsFile .\releases\test-01.yaml -AzureSql -AzureMongo
```

Скрипта отвара Chrome за Selenium тест; не затварај прозор док ради. Пад теста не враћа претходни деплој аутоматски. После преласка увек проследи `-AzureMongo`; без њега се поново користи Mongo у кластеру. Smoke проверава празну претрагу; за DocumentDB провери и креирање смештаја/доступности → претрагу → одобравање/отказивање резервације.

Апликација: http://booking-aks-bff6a774.italynorth.cloudapp.azure.com

```powershell
kubectl --context booking-aks -n booking get pods -o wide
kubectl --context booking-aks -n booking get pvc,ingress
```

Само smoke тест, без деплоја:

```powershell
python .\scripts\smoke.py http://booking-aks-bff6a774.italynorth.cloudapp.azure.com --headed
```

Ако први старт врати 502, провери логове пре поновног теста. Познат проблем: паузирана SQL база може вратити 40613 при буђењу, а readiness провера још није додата.

```powershell
kubectl --context booking-aks -n booking logs deployment/user-service --tail=80
kubectl --context booking-aks -n booking logs deployment/user-service --previous --tail=80
```

## Port-forward — Grafana, Prometheus, Jaeger, Seq

Користи док AKS ради. Свака port-forward команда иде у засебан терминал; остави га отвореним. `Ctrl+C` прекида прослеђивање.

Ако `booking-aks` context није подешен:

```powershell
az aks get-credentials --subscription bff6a774-701a-4987-b913-5288d9ef784e -g booking-aks-lab -n booking-aks --context booking-aks --overwrite-existing
```

**Grafana:** http://localhost:3000 — lab пријава `admin` / `admin`, ако није промењена.

```powershell
kubectl --context booking-aks -n booking port-forward service/grafana 3000:3000
```

**Prometheus:** http://localhost:9090 — targets: http://localhost:9090/targets

```powershell
kubectl --context booking-aks -n booking port-forward service/prometheus 9090:9090
```

**Jaeger:** http://localhost:16687

```powershell
kubectl --context booking-aks -n booking port-forward service/jaeger 16687:80
```

**Seq:** http://localhost:8081

```powershell
kubectl --context booking-aks -n booking port-forward service/seq 8081:80
```

## Azure гашење — SQL, DocumentDB и Key Vault остају

Изврши редом. Ово брише AKS и његове дискове. Azure DocumentDB остаје; ако још користиш Mongo у кластеру, његови подаци се губе. Не бриши `booking-aks-lab` нити покрећи destroy за `infra/azure-key-vault`, `infra/azure-sql` или `infra/azure-mongo` при редовном гашењу.

```powershell
helm uninstall booking --kube-context booking-aks -n booking --wait --timeout 10m
```

```powershell
terraform "-chdir=infra/azure-ingress" plan -destroy "-out=ingress-destroy.tfplan"
terraform "-chdir=infra/azure-ingress" apply "ingress-destroy.tfplan"
```

```powershell
terraform "-chdir=infra/azure" plan -destroy "-var-file=azure-sql.tfvars" "-out=aks-destroy.tfplan"
terraform "-chdir=infra/azure" apply "aks-destroy.tfplan"
```

Провери шта је остало; празан AKS списак сам по себи није потврда да је цео Azure трошак нула:

```powershell
az resource list --subscription bff6a774-701a-4987-b913-5288d9ef784e --query "[].{Name:name,Type:type,Group:resourceGroup}" -o table
```

<a id="first-setup"></a>

## Једнократна припрема — само ако vault и базе још не постоје

Већ урађено за тренутно окружење. Ако ресурси постоје, а локални state недостаје, прво врати или увези state; не примењуј план који поново креира постојеће ресурсе.

### 1. Key Vault

```powershell
terraform "-chdir=infra/azure-key-vault" init
terraform "-chdir=infra/azure-key-vault" plan "-out=vault.tfplan"
terraform "-chdir=infra/azure-key-vault" apply "vault.tfplan"
```

У порталу: **Key Vault → kv-booking-bff6a774 → Secrets → Generate/Import**. Додај `sql-admin-password` са јаком SQL администраторском лозинком. Не мењај постојећу лозинку ако SQL сервер већ постоји.

За апликацију су потребни и `rabbitmq-user`, `rabbitmq-pass`, `mongo-root-password`, `mongo-conn-search`, као и пет `connstr-*` тајни из табеле испод. MongoDB connection string мора користити hostname `mongo` и лозинку која одговара `mongo-root-password`.

### 2. Пет SQL база

Учитај лозинку блоком из корака **Azure deploy → 4**, па у истом терминалу:

```powershell
az provider register --namespace Microsoft.Sql --subscription bff6a774-701a-4987-b913-5288d9ef784e --wait
$sqlClientIp = (Invoke-RestMethod 'https://api.ipify.org').Trim()
$env:TF_VAR_allowed_ipv4 = @{ operator = $sqlClientIp } | ConvertTo-Json -Compress
terraform "-chdir=infra/azure-sql" init
terraform "-chdir=infra/azure-sql" plan "-out=sql.tfplan"
terraform "-chdir=infra/azure-sql" apply "sql.tfplan"
```

Провери да свих пет има `Free=True` и `OnLimit=AutoPause`:

```powershell
az sql db list --subscription bff6a774-701a-4987-b913-5288d9ef784e -g booking-aks-lab -s sql-booking-it-bff6a774 --query "[?name!='master'].{Name:name,State:status,Free:useFreeLimit,OnLimit:freeLimitExhaustionBehavior}" -o table
```

### 3. SQL корисници и connection string-ови

У свакој бази отвори **Query editor**, пријави се Microsoft Entra налогом и покрени [configure-service-user.sql](infra/azure-sql/configure-service-user.sql). Замени лозинку **само у `DECLARE @password`**, не и у `IF` провери. Користи различиту лозинку од најмање 16 знакова са великим/малим словима, бројевима и симболима. Не чувај попуњен SQL фајл у Git-у. Скрипта не мења лозинку већ постојећег корисника.

| База | Корисник | Key Vault тајна |
| --- | --- | --- |
| UserServiceDb | booking_user | connstr-user |
| AccommodationServiceDb | booking_accommodation | connstr-accommodation |
| ReservationServiceDb | booking_reservation | connstr-reservation |
| RatingServiceDb | booking_rating | connstr-rating |
| NotificationServiceDb | booking_notification | connstr-notification |

За сваку тајну: **Secrets → назив тајне → New Version → Secret value → Create**. Замени базу, корисника и лозинку у овом шаблону:

```text
Server=tcp:sql-booking-it-bff6a774.database.windows.net,1433;Database=<DATABASE>;User ID=<USER>;Password=<PASSWORD>;Encrypt=True;TrustServerCertificate=False;Connect Timeout=120;
```

За овај ручни шаблон користи лозинку без `;` и наводника. По завршетку настави са **Azure deploy → 2. AKS**.

## Minikube deploy

Потребан је локални `booking-platform/values.secrets.yaml` са SQL/Mongo/RabbitMQ вредностима; не користи Azure SQL connection string-ове. Ако фајл још немаш, направи га по шаблону испод и замени `<SQL_PASSWORD>` и `<MONGO_PASSWORD>`:

```yaml
secrets:
  sqlserver:
    saPassword: "<SQL_PASSWORD>"
  rabbitmq:
    user: "guest"
    pass: "guest"
  mongo:
    rootPassword: "<MONGO_PASSWORD>"
  connStrings:
    user: "Server=devops-sql,1433;Database=UserServiceDb;User Id=sa;Password=<SQL_PASSWORD>;TrustServerCertificate=True"
    accommodation: "Server=devops-sql,1433;Database=AccommodationServiceDb;User Id=sa;Password=<SQL_PASSWORD>;TrustServerCertificate=True"
    reservation: "Server=devops-sql,1433;Database=ReservationServiceDb;User Id=sa;Password=<SQL_PASSWORD>;TrustServerCertificate=True"
    rating: "Server=devops-sql,1433;Database=RatingServiceDb;User Id=sa;Password=<SQL_PASSWORD>;TrustServerCertificate=True"
    notification: "Server=devops-sql,1433;Database=NotificationServiceDb;User Id=sa;Password=<SQL_PASSWORD>;TrustServerCertificate=True"
  mongoConn:
    search: "mongodb://root:<MONGO_PASSWORD>@mongo:27017/admin"
```

1. Покрени Docker Desktop (Linux containers), па:

   ```powershell
   minikube start -p minikube --driver=docker --cpus=2 --memory=8000
   minikube addons enable ingress -p minikube
   ```

2. У `C:\Windows\System32\drivers\etc\hosts`, као администратор, додај:

   ```text
   127.0.0.1 booking.local
   127.0.0.1 grafana.booking.local
   127.0.0.1 prometheus.booking.local
   127.0.0.1 jaeger.booking.local
   127.0.0.1 seq.booking.local
   ```

3. У засебном администраторском терминалу покрени и остави:

   ```powershell
   minikube tunnel -p minikube
   ```

4. Са инсталираним Python зависностима из првог одељка, покрени деплој:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Deploy-Local.ps1 -VersionsFile .\releases\test-01.yaml
   ```

Апликација: http://booking.local. За локални port-forward користи исте команде као изнад, са `--context minikube`.

Заустављање без брисања кластера:

```powershell
minikube stop -p minikube
```
