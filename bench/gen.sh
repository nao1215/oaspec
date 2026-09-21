#!/bin/sh
# Writes the inputs of the himorime suite in bench/. Both revisions of a
# comparison run the working tree's copy (${head_root}/gen.sh).
#
#   sh gen.sh project N DIR   an oaspec project in DIR: DIR/openapi.yaml, an
#                             OpenAPI 3.0 document of exactly N operations
#                             (N even, N >= 2), and DIR/oaspec.yaml, which
#                             generates package api into DIR/generated.
#                             Deterministic: the same N always writes the
#                             same bytes.
#   sh gen.sh broken N DIR    the same project without the required info
#                             object, which validate and generate reject
#                             with exit 1.
#
# Every two operations share one resource: GET /resources{i} (a query
# parameter and an array response) and POST /resources{i} (a JSON request
# body and a 201 response), with two component schemas per resource that
# use an enum, a required list, an array and a $ref to a shared schema, so
# the parser, the resolver and every generated module get work to do.
set -eu

case "$1" in
project | broken)
	kind="$1"
	n="$2"
	dir="$3"
	if [ $((n % 2)) -ne 0 ] || [ "$n" -lt 2 ]; then
		echo "gen.sh: the number of operations must be even and at least 2, got $n" >&2
		exit 2
	fi
	mkdir -p "$dir"
	awk -v resources="$((n / 2))" -v kind="$kind" 'BEGIN {
		print "openapi: \"3.0.3\""
		if (kind == "project") {
			print "info:"
			print "  title: oaspec benchmark"
			print "  version: \"1.0.0\""
		}
		print "paths:"
		for (i = 1; i <= resources; i++) {
			print "  /resources" i ":"
			print "    get:"
			print "      operationId: listResources" i
			print "      tags: [group" (i % 10) "]"
			print "      parameters:"
			print "        - name: limit"
			print "          in: query"
			print "          required: false"
			print "          schema:"
			print "            type: integer"
			print "            minimum: 1"
			print "            maximum: 100"
			print "      responses:"
			print "        \"200\":"
			print "          description: The resources"
			print "          content:"
			print "            application/json:"
			print "              schema:"
			print "                type: array"
			print "                items:"
			print "                  $ref: \"#/components/schemas/Resource" i "\""
			print "        \"404\":"
			print "          description: Not found"
			print "    post:"
			print "      operationId: createResource" i
			print "      tags: [group" (i % 10) "]"
			print "      requestBody:"
			print "        required: true"
			print "        content:"
			print "          application/json:"
			print "            schema:"
			print "              $ref: \"#/components/schemas/NewResource" i "\""
			print "      responses:"
			print "        \"201\":"
			print "          description: Created"
			print "          content:"
			print "            application/json:"
			print "              schema:"
			print "                $ref: \"#/components/schemas/Resource" i "\""
		}
		print "components:"
		print "  schemas:"
		print "    Owner:"
		print "      type: object"
		print "      required: [id, name]"
		print "      properties:"
		print "        id:"
		print "          type: integer"
		print "        name:"
		print "          type: string"
		print "          minLength: 1"
		for (i = 1; i <= resources; i++) {
			print "    Resource" i ":"
			print "      type: object"
			print "      required: [id, name, status]"
			print "      properties:"
			print "        id:"
			print "          type: integer"
			print "          format: int64"
			print "        name:"
			print "          type: string"
			print "          maxLength: 64"
			print "        status:"
			print "          type: string"
			print "          enum: [active, archived, deleted]"
			print "        tags:"
			print "          type: array"
			print "          items:"
			print "            type: string"
			print "        owner:"
			print "          $ref: \"#/components/schemas/Owner\""
			print "    NewResource" i ":"
			print "      type: object"
			print "      required: [name]"
			print "      properties:"
			print "        name:"
			print "          type: string"
			print "          maxLength: 64"
			print "        tags:"
			print "          type: array"
			print "          items:"
			print "            type: string"
		}
	}' > "$dir/openapi.yaml"
	cat > "$dir/oaspec.yaml" <<'EOF'
input: ./openapi.yaml
package: api
output:
  dir: ./generated
EOF
	;;
*)
	echo "gen.sh: unknown kind $1" >&2
	exit 2
	;;
esac
