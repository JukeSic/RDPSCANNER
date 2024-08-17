#!/bin/bash

# Clear the terminal
clear

# ASCII Art Tag (using 'cat << EOF' for multi-line strings)
cat << "EOF"
 _____  _____  _____
|  __ \|  __ \|  __ \                               
| |__) | |  | | |__) |                              
|  _  /| |  | |  ___/                               
| | \ \| |__| | |                                   
|_|  \_\_____/|_|          _   _ _   _ ______ _____  
    / ____|/ ____|   /\   | \ | | \ | |  ____|  __ \ 
   | (___ | |       /  \  |  \| |  \| | |__  | |__) |
    \___ \| |      / /\ \ | . ` | . ` |  __| |  _  /  
    ____) | |____ / ____ \| |\  | |\  | |____| | \ \ 
   |_____/ \_____/_/    \_\_| \_|_| \_|______|_|  \_\
                                                    
nmap plugin by JukeSic
                                                    
EOF

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
   echo "Please run this script as root using sudo."
   exit 1
fi

# Ensure /usr/bin is in PATH
export PATH=$PATH:/usr/bin

# Function to check if a command exists and install it if not
install_if_missing() {
   local cmd=$1
   local pkg=$2
   local cmd_path=$(command -v "$cmd")

   echo "Checking for $cmd..."

   if [ -z "$cmd_path" ]; then
       echo "$cmd not found, installing $pkg..." | tee -a "$LOG_FILE"
       apt-get update
       apt-get install -y "$pkg"
       if [ $? -ne 0 ]; then
           echo "Failed to install $pkg. Exiting." | tee -a "$LOG_FILE"
           exit 1
       fi
   else
       echo "$cmd is already installed at $cmd_path." | tee -a "$LOG_FILE"
   fi
}

# Trap signals to ensure proper cleanup
cleanup() {
    echo "$(date): Terminating script and cleaning up..." | tee -a "$LOG_FILE"
    pkill -P $$  # Kill all background processes that are children of this script
    wait         # Wait for all background processes to exit
    echo -e "\nScanning complete. Results saved to $OUTPUT_FILE. Log saved to $LOG_FILE."
    exit 0
}

trap cleanup SIGINT SIGTERM

# Ask the user to input the directory containing .cidr files
read -rp "Please enter the path to the directory containing .cidr files: " CIDR_DIR

# Validate the CIDR_DIR
if [ ! -d "$CIDR_DIR" ]; then
   echo "The provided path is not a directory. Exiting."
   exit 1
fi

# Ask the user to input the directory for output and log files
read -rp "Please enter the path to the directory where output and log files should be saved: " OUTPUT_LOG_DIR

# Validate the OUTPUT_LOG_DIR
if [ ! -d "$OUTPUT_LOG_DIR" ]; then
   echo "The provided path is not a directory. Exiting."
   exit 1
fi

# Define the output and log files
OUTPUT_FILE="$OUTPUT_LOG_DIR/hit.txt"
LOG_FILE="$OUTPUT_LOG_DIR/scan.log"

# Ensure the script has write permissions to the directories and files
chmod -R u+w "$CIDR_DIR"
chmod -R u+w "$OUTPUT_LOG_DIR"

# Clear or create the log file
echo -n > "$LOG_FILE"

# Clear or create the output file
echo -n > "$OUTPUT_FILE"

# Check and install dependencies
install_if_missing nmap nmap

# Function to display a list of .cidr files in a grid format with numbers and prompt the user to select one
select_cidr_file() {
   echo "Please select a .cidr file from the following list:" | tee -a "$LOG_FILE"

   echo "Searching in: $CIDR_DIR" | tee -a "$LOG_FILE"  # Print the directory being searched
   # Find and list .cidr files, handle potential errors
   files=($(find "$CIDR_DIR" -maxdepth 1 -type f -name "*.cidr" 2>&1 | tee -a "$LOG_FILE"))
   if [ $? -ne 0 ]; then
       echo "Error occurred while searching for .cidr files:" >&2 | tee -a "$LOG_FILE"
       echo "${files[@]}" >&2 | tee -a "$LOG_FILE"
       exit 1
   fi
   total_files=${#files[@]}

   # Check if there are no files
   if [ $total_files -eq 0 ]; then
       echo "No .cidr files found in $CIDR_DIR." | tee -a "$LOG_FILE"
       exit 1
   fi

   # Define number of columns and rows for grid layout
   columns=5
   rows=$(( (total_files + columns - 1) / columns ))

   # Display files in a grid format with numbers for easy selection
   index=1
   for ((i = 0; i < rows; i++)); do
       for ((j = 0; j < columns; j++)); do
           file_index=$((i * columns + j))
           if [ $file_index -lt $total_files ]; then
               filename=$(basename "${files[$file_index]}")
               printf "%-5d %-30s" "$index" "$filename" | tee -a "$LOG_FILE"
               ((index++))
           fi
       done
       echo | tee -a "$LOG_FILE"
   done

   # Get user input for file selection, with input validation
   while true; do
       read -rp "Enter the number of the file to select: " selection
       if [[ $selection =~ ^[0-9]+$ ]] && [ $selection -gt 0 ] && [ $selection -le $total_files ]; then
           CIDR_FILE="${files[$((selection-1))]}"
           echo "You selected: $CIDR_FILE" | tee -a "$LOG_FILE"
           break
       else
           echo "Invalid selection. Please enter a number corresponding to the file in the list." | tee -a "$LOG_FILE"
       fi
   done
}

# Call the function to select a .cidr file
select_cidr_file

# Function to visually represent the scan progress
show_progress() {
   local current_ip="$1"
   local total_ips="$2"
   local ip_index="$3"
   # Calculate and print the percentage complete
   local percentage=$((ip_index * 100 / total_ips))
   echo -ne "Scanning progress: $percentage% ($ip_index/$total_ips IPs) - Scanning $current_ip\r"
}

# Function to run Nmap with enhanced error handling and output parsing
run_nmap() {
    local ip_block="$1"
    echo "$(date): Running nmap on $ip_block..." | tee -a "$LOG_FILE"
    # Run nmap with verbose output and capture stderr
    nmap_output=$(nmap -p 3389 --open -T4 -vv "$ip_block" 2>&1 | tee -a "$LOG_FILE")

    # Check Nmap exit status
    if [ $? -ne 0 ]; then
        echo "$(date): Nmap encountered an error for $ip_block. Check the log for details." | tee -a "$LOG_FILE"
    else
        # Extract IP from output using awk (more flexible)
        open_ips=$(echo "$nmap_output" | awk '/^Nmap scan report for / {print $5}')
        if [ -n "$open_ips" ]; then
            echo "$(date): Open IPs found: $open_ips" | tee -a "$LOG_FILE"
            echo "$open_ips" >> "$OUTPUT_FILE"
            echo "Open IP found: $open_ips"  # This line echoes the result to the terminal in real-time
        else
            echo "$(date): No open ports found for $ip_block" | tee -a "$LOG_FILE"
        fi
    fi

    # Wait for Nmap to complete (if running in background)
    wait
}

# Loop through each line in the .cidr file with visual feedback and debugging output
total_ips=$(grep -v -E '^\s*$' "$CIDR_FILE" | wc -l)
ip_index=1

grep -v -E '^\s*$' "$CIDR_FILE" | while read -r ip_block; do
    echo "$(date): Scanning $ip_block..." | tee -a "$LOG_FILE"

    show_progress "$ip_block" "$total_ips" "$ip_index"

    run_nmap "$ip_block"

    ((ip_index++))
done

wait  # Ensure all background processes complete before finishing

echo -e "\nScanning complete. Results saved to $OUTPUT_FILE. Log saved to $LOG_FILE."
