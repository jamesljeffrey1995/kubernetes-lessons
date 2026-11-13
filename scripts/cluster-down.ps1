# Deletes the "lessons" kind cluster. Everything inside it is gone; your files are not touched.
kind delete cluster --name lessons
exit $LASTEXITCODE
