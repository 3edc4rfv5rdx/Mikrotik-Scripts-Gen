# Два провайдера и один WireGuard-туннель

Автоматика не в туннеле, а в WAN-failover: WireGuard идёт по обычной таблице
маршрутизации и сам уходит через другой аплинк, когда меняется default route.

## Рецепт

```
/ip/route add dst-address=8.8.8.8/32 gateway=<gw-оптики> scope=10
/ip/route add dst-address=1.1.1.1/32 gateway=<gw-lte>    scope=10
/ip/route add dst-address=0.0.0.0/0 gateway=8.8.8.8 target-scope=11 distance=1 check-gateway=ping
/ip/route add dst-address=0.0.0.0/0 gateway=1.1.1.1 target-scope=11 distance=2 check-gateway=ping
```

Пробники обязаны быть разные: с одним адресом проверка пойдёт по уже активному
маршруту и второй канал не проверится никогда.

## Кто переключает

Сам RouterOS, скрипты и netwatch не нужны. `check-gateway=ping` шлёт ICMP на
шлюз своего маршрута раз в 10 секунд, таймаут 10 секунд; после двух таймаутов
подряд маршрут уходит в inactive и активным становится следующий по distance.
Первый же ответ возвращает его обратно.

## scope и target-scope

Маршрут со `scope` больше, чем `target-scope` у ищущего, не используется для
резолва next-hop. По умолчанию: connected — 10, статические — 30, динамические —
40, `target-scope=10` (то есть только через connected). Поэтому пробному `/32`
ставим `scope=10`, а default route — `target-scope=11`, иначе 8.8.8.8 как шлюз
не разрешится.

## Туннель

Настраивать нечего: у стороны с двумя провайдерами меняется исходящий адрес,
вторая узнаёт новый endpoint из аутентифицированного handshake (roaming),
`persistent-keepalive=25s` укладывает переключение примерно в полминуты.

## Условия

- Дозваниваться должна сторона с двумя провайдерами — иначе у второй прописан
  статический `endpoint-address`, неверный после ухода на LTE (лечится DDNS).
- Masquerade нужен на обоих WAN-интерфейсах.
- Резерв работает только при разных `distance`; с одинаковыми будет ECMP.

Источники: [IP Routing](https://help.mikrotik.com/docs/spaces/ROS/pages/328084/IP+Routing),
[Using scope and target-scope attributes](https://wiki.mikrotik.com/Manual:Using_scope_and_target-scope_attributes),
[форум про check-gateway](https://forum.mikrotik.com/t/check-gateway-more-than-each-10s/44969).
