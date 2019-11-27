set -euo pipefail

host={{ .Values.host }}

dirname=/data/${BACKUP_NAME}
echo "making dir ${dirname}"
mkdir -p ${dirname}

password_str=""
if [ -n "${TIDB_PASSWORD}" ];
then
    password_str="-p${TIDB_PASSWORD}"
fi

gc_life_time=`/usr/bin/mysql -h${host} -P4000 -u${TIDB_USER} ${password_str} -Nse "select variable_value from mysql.tidb where variable_name='tikv_gc_life_time';"`
echo "Old TiKV GC life time is ${gc_life_time}"

function reset_gc_lifetime() {
echo "Reset TiKV GC life time to ${gc_life_time}"
/usr/bin/mysql -h${host} -P4000 -u${TIDB_USER} ${password_str} -Nse "update mysql.tidb set variable_value='${gc_life_time}' where variable_name='tikv_gc_life_time';"
/usr/bin/mysql -h${host} -P4000 -u${TIDB_USER} ${password_str} -Nse "select variable_name,variable_value from mysql.tidb where variable_name='tikv_gc_life_time';"
}
trap "reset_gc_lifetime" EXIT

echo "Increase TiKV GC life time to 3h"
/usr/bin/mysql -h${host} -P4000 -u${TIDB_USER} ${password_str} -Nse "update mysql.tidb set variable_value='3h' where variable_name='tikv_gc_life_time';"
/usr/bin/mysql -h${host} -P4000 -u${TIDB_USER} ${password_str} -Nse "select variable_name,variable_value from mysql.tidb where variable_name='tikv_gc_life_time';"


if [ -n "{{ .Values.initialCommitTs }}" ];
then
    snapshot_args="--tidb-snapshot={{ .Values.initialCommitTs }}"
    echo "commitTS = {{ .Values.initialCommitTs }}" > ${dirname}/savepoint
    cat ${dirname}/savepoint
fi

/mydumper \
  --outputdir=${dirname} \
  --host=${host} \
  --port=4000 \
  --user=${TIDB_USER} \
  --password=${TIDB_PASSWORD} \
  --long-query-guard=3600 \
  --tidb-force-priority=LOW_PRIORITY \
  {{ .Values.backupOptions }} ${snapshot_args:-}

bucket={{ .Values.gcp.bucket }}
backup_name="$(basename "${dirname}")"
backup_base_dir="$(dirname "${dirname}")"

{{- if .Values.gcp }}
creds=${GOOGLE_APPLICATION_CREDENTIALS:-""}
if ! [[ -z $creds ]] ; then
creds = "service_account_file = ${creds}"
fi

cat <<EOF > /tmp/rclone.conf
[gcp]
type = google cloud storage
bucket_policy_only = true
$creds
EOF

  tar -cf - ${backup_name} -C ${backup_base_dir} | pigz -p 16 > ${backup_base_dir}/${backup_name}.tgz \
  | rclone --config /tmp/rclone.conf rcat gcp:${bucket}/${backup_name}/${backup_name}.tgz
{{- end }}

{{- if .Values.ceph }}
uploader \
  --cloud=ceph \
  --bucket={{ .Values.ceph.bucket }} \
  --endpoint={{ .Values.ceph.endpoint }} \
  --backup-dir=${dirname}
{{- end }}

{{- if .Values.s3 }}
uploader \
  --cloud=aws \
  --region={{ .Values.s3.region }} \
  --bucket={{ .Values.s3.bucket }} \
  --backup-dir=${dirname}
{{- end }}
