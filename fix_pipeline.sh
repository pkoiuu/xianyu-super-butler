#!/bin/bash
# 全自动流水线：等待构建完成 -> 下载制品 -> docker load -> 重建容器 -> 验证
LOG=/tmp/fix_pipeline.log
RUN_ID=36860082742
cd /opt/xianyu-butler

echo "=== PIPELINE START $(date '+%F %T') ===" > $LOG

# 1. 等待构建完成
for i in $(seq 1 60); do
  STATUS=$(gh run view $RUN_ID -R pkoiuu/xianyu-super-butler --json status,conclusion -q '.status + "/" + (.conclusion // "pending")' 2>/dev/null)
  echo "[$i] $(date '+%T') build: $STATUS" >> $LOG
  if [[ "$STATUS" == completed/* ]]; then break; fi
  sleep 30
done

if [[ "$STATUS" != "completed/success" ]]; then
  echo "BUILD_FAILED: $STATUS" >> $LOG
  gh run view $RUN_ID -R pkoiuu/xianyu-super-butler --log-failed 2>&1 | tail -50 >> $LOG
  echo "=== PIPELINE ABORT $(date '+%F %T') ===" >> $LOG
  exit 1
fi
echo "BUILD_OK $(date '+%T')" >> $LOG

# 2. 下载制品
rm -rf artifact_dl2 && mkdir -p artifact_dl2
gh run download $RUN_ID -R pkoiuu/xianyu-super-butler -n xianyu-butler-image -D artifact_dl2/ 2>&1 >> $LOG
if [ ! -f artifact_dl2/xianyu-butler-image.tar.gz ]; then
  echo "DOWNLOAD_FAILED" >> $LOG
  echo "=== PIPELINE ABORT $(date '+%F %T') ===" >> $LOG
  exit 1
fi
echo "DOWNLOAD_OK $(date '+%T') size=$(du -h artifact_dl2/xianyu-butler-image.tar.gz | cut -f1)" >> $LOG

# 3. docker load
docker load -i artifact_dl2/xianyu-butler-image.tar.gz >> $LOG 2>&1
echo "LOAD_EXIT=$? $(date '+%T')" >> $LOG

# 4. 重建容器（数据卷挂载保留，仅重建容器层）
docker compose -f docker-compose.prod.yml up -d --force-recreate >> $LOG 2>&1
echo "RECREATE_EXIT=$? $(date '+%T')" >> $LOG

# 5. 等待健康
for i in $(seq 1 12); do
  sleep 5
  HEALTH=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8092/health 2>/dev/null)
  CSTATE=$(docker inspect -f '{{.State.Health.Status}}' xianyu-auto-reply 2>/dev/null)
  echo "[health $i] http=$HEALTH container=$CSTATE" >> $LOG
  if [ "$HEALTH" = "200" ] && [ "$CSTATE" = "healthy" ]; then
    echo "ALL_OK $(date '+%T')" >> $LOG
    docker inspect -f 'Mem={{.HostConfig.Memory}} Cpus={{.HostConfig.NanoCpus}} OOM={{.State.OOMKilled}} Restart={{.HostConfig.RestartPolicy.Name}}' xianyu-auto-reply >> $LOG
    echo "=== PIPELINE DONE $(date '+%F %T') ===" >> $LOG
    exit 0
  fi
done

echo "HEALTH_TIMEOUT" >> $LOG
echo "=== PIPELINE DONE-WITH-WARNING $(date '+%F %T') ===" >> $LOG
