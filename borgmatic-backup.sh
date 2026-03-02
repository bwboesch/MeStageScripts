#!/bin/bash

# Überprüfen der Anzahl der übergebenen Argumente
if [ $# -lt 1 ]; then
  echo "Es muss mindestens ein Parameter angegeben werden: create oder prune"
  exit 1
fi

source /root/.bashrc

# Überprüfen und Verarbeiten der Parameter
operation=""

while getopts ":v:" opt; do
  case $opt in
    v)
      echo "$OPTARG"
      verbose="$OPTARG"
      ;;
    \?)
      echo "Ungültige Option: -$OPTARG" >&2
      exit 1
      ;;
  esac
done

# Die restlichen Argumente überprüfen und die Operation festlegen
shift $((OPTIND-1))
if [ "$1" == "create" ]; then
  operation="create"
elif [ "$1" == "prune" ]; then
  operation="prune"
else
  echo "Ungültige Operation: $1. Es muss entweder 'create' oder 'prune' sein."
  exit 1
fi

echo $operation
echo $verbose

# Überprüfen, ob der Verbose-Parameter vorhanden ist
if [ -n "$verbose" ]; then
  /root/.local/bin/borgmatic "$operation" -v "$verbose"
else
  /root/.local/bin/borgmatic "$operation"
fi
