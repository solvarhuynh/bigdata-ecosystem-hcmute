"""
Bài 2: Tính giá trị trung bình độ dài các từ (Word Length Mean) bằng PySpark
- Mean = Tổng số ký tự của tất cả các từ / Tổng số từ
"""
import sys
import re
from pyspark.sql import SparkSession

def main():
    spark = SparkSession.builder \
        .appName("BigData-N14-WordMean") \
        .getOrCreate()

    sc = spark.sparkContext
    sc.setLogLevel("WARN")

    input_path = sys.argv[1] if len(sys.argv) > 1 else "hdfs:///nhom14/input/word/description.txt"
    print(f"=== Đọc dữ liệu từ đường dẫn: {input_path} ===")

    lines = sc.textFile(input_path)

    # Tách từ và lọc bỏ rỗng
    words = lines.flatMap(lambda line: re.split(r'\W+', line.strip())) \
                 .filter(lambda word: len(word) > 0)

    # Ánh xạ mỗi từ thành tuple (độ_dài, 1)
    word_stats = words.map(lambda w: (len(w), 1))

    # aggregate() giữ kết quả đúng nhưng không gọi reduce() trên RDD rỗng.
    total_length, total_count = word_stats.aggregate(
        (0, 0),
        lambda acc, value: (acc[0] + value[0], acc[1] + value[1]),
        lambda left, right: (left[0] + right[0], left[1] + right[1]),
    )

    mean_length = total_length / float(total_count) if total_count > 0 else 0.0

    print("=== KẾT QUẢ ĐỘ DÀI TRUNG BÌNH (WORD LENGTH MEAN) ===")
    print(f"Tổng số từ: {total_count}")
    print(f"Tổng số ký tự: {total_length}")
    print(f"Độ dài từ trung bình (Mean): {mean_length:.4f}")

    spark.stop()

if __name__ == "__main__":
    main()
