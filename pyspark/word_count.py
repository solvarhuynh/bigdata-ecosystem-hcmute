"""
Bài 1: Đếm số lần xuất hiện của từ (Word Count) bằng PySpark
- Xử lý case-insensitive (chuyển về chữ thường)
- Lọc ký tự trắng, loại bỏ dấu câu cơ bản
"""
import sys
import re
from pyspark.sql import SparkSession

def main():
    spark = SparkSession.builder \
        .appName("BigData-N14-WordCount") \
        .getOrCreate()

    sc = spark.sparkContext
    sc.setLogLevel("WARN")

    input_path = sys.argv[1] if len(sys.argv) > 1 else "hdfs:///test_bigdata/input/description.txt"
    print(f"=== Đọc dữ liệu từ đường dẫn: {input_path} ===")

    lines = sc.textFile(input_path)

    # Tách từ, chuyển thành chữ thường và lọc bỏ từ rỗng
    words = lines.flatMap(lambda line: re.split(r'\W+', line.lower())) \
                 .filter(lambda word: len(word) > 0)

    # Đếm số lần xuất hiện
    word_counts = words.map(lambda word: (word, 1)) \
                       .reduceByKey(lambda a, b: a + b) \
                       .sortBy(lambda item: item[1], ascending=False)

    print("=== KẾT QUẢ ĐẾM TỪ (WORD COUNT) ===")
    for word, count in word_counts.collect():
        print(f"{word}: {count}")

    spark.stop()

if __name__ == "__main__":
    main()
